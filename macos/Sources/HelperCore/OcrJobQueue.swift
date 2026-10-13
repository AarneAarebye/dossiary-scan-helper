import Foundation
import Security

public struct OcrJobInput: Sendable {
    public let pages: [PageImage]
    public let languages: [String]
    /// fake:ocr only: the text of each page, which FakeOcrEngine writes into the result.
    public let fakeTexts: [String]?
    public let createdAt: Date
}

/// Makes one searchable PDF. Throws when no searchable PDF could be made at all (the job then answers 500).
public protocol OcrEngine: Sendable {
    func makeSearchable(_ input: OcrJobInput) async throws -> Data
}

public enum OcrJobStatus: Equatable, Sendable {
    case pending(state: String, position: Int)
    case done(name: String, pages: Int, pdf: Data)
    case failed(String)
    case unknown
}

/// PROTOCOL.md "Background OCR": jobs run one at a time, live on disk until fetched (at most 7 days), and
/// resume after a restart. Layout: <root>/<id>/meta.json, page-<n>.img, result.pdf.
public actor OcrJobQueue {
    public static let retention: TimeInterval = 7 * 24 * 3600
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dossiary-scan-helper/ocr-jobs")
    }

    struct Meta: Codable {
        var name: String
        var pages: Int
        var dpis: [Int]
        var languages: [String]
        var fakeTexts: [String]?
        var createdAt: Date
        var sequence: Int
        var state: String       // "queued", "done", "failed"
        var message: String?
    }

    private let root: URL
    private let engine: OcrEngine
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var order: [String] = []   // unfinished jobs, oldest first; order[0] runs
    private var running: String?
    private var nextSequence = 0
    private var worker: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(root: URL, engine: OcrEngine, now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.root = root; self.engine = engine; self.now = now; self.log = log
    }

    public static func isValidID(_ id: String) -> Bool {
        id.count >= 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func readMeta(_ id: String) -> Meta? {
        guard let data = try? Data(contentsOf: dir(id).appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func writeMeta(_ meta: Meta, _ id: String) throws {
        try JSONEncoder().encode(meta).write(to: dir(id).appendingPathComponent("meta.json"), options: .atomic)
    }

    private func remove(_ id: String) { try? FileManager.default.removeItem(at: dir(id)) }

    private func expired(_ meta: Meta) -> Bool { now().timeIntervalSince(meta.createdAt) > OcrJobQueue.retention }

    /// Loads jobs left from an earlier run: drops expired ones and resumes unfinished ones in their order.
    public func start() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var unfinished: [(Int, String)] = []
        for id in names where OcrJobQueue.isValidID(id) {
            guard let meta = readMeta(id), !expired(meta) else { remove(id); continue }
            nextSequence = max(nextSequence, meta.sequence + 1)
            if meta.state == "queued" { unfinished.append((meta.sequence, id)) }
        }
        order = unfinished.sorted { $0.0 < $1.0 }.map(\.1)
        if !order.isEmpty { log("Resuming \(order.count) text recognition job(s).") }
        kick()
    }

    public func submit(pages: [PageImage], name: String, languages: [String], fakeTexts: [String]?) throws -> String {
        let id = OcrJobQueue.newID()
        let folder = dir(id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, page) in pages.enumerated() {
                try page.data.write(to: folder.appendingPathComponent("page-\(index + 1).img"))
            }
            let meta = Meta(name: name, pages: pages.count, dpis: pages.map(\.dpi), languages: languages,
                            fakeTexts: fakeTexts, createdAt: now(), sequence: nextSequence, state: "queued", message: nil)
            try writeMeta(meta, id)
        } catch {
            remove(id)
            throw error
        }
        nextSequence += 1
        order.append(id)
        log("Text recognition job \(id.prefix(6))… queued for \(name).")
        kick()
        return id
    }

    public func fetch(_ id: String) -> OcrJobStatus {
        guard OcrJobQueue.isValidID(id), let meta = readMeta(id) else { return .unknown }
        if expired(meta) {
            order.removeAll { $0 == id && $0 != running }
            if running != id { remove(id) }
            return .unknown
        }
        switch meta.state {
        case "done":
            guard let pdf = try? Data(contentsOf: dir(id).appendingPathComponent("result.pdf")) else {
                remove(id); return .failed("The searchable PDF went missing.")
            }
            remove(id)
            return .done(name: meta.name, pages: meta.pages, pdf: pdf)
        case "failed":
            remove(id)
            return .failed(meta.message ?? "Text recognition failed.")
        default:
            let position = order.firstIndex(of: id) ?? 0
            return .pending(state: id == running ? "running" : "queued", position: position)
        }
    }

    /// Tests only: returns once no job is queued or running.
    public func waitUntilIdle() async {
        if worker == nil && order.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func kick() {
        guard worker == nil, !order.isEmpty else { return }
        worker = Task { await self.runAll() }
    }

    private func runAll() async {
        while let id = order.first {
            running = id
            await runOne(id)
            running = nil
            if order.first == id { order.removeFirst() }
            expireFinished()
        }
        worker = nil
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func runOne(_ id: String) async {
        guard var meta = readMeta(id) else { return }
        let folder = dir(id)
        var pages: [PageImage] = []
        for index in 0..<meta.pages {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("page-\(index + 1).img")) else {
                meta.state = "failed"; meta.message = "A scanned page of this job went missing."
                try? writeMeta(meta, id); return
            }
            pages.append(PageImage(data: data, dpi: meta.dpis[index]))
        }
        let input = OcrJobInput(pages: pages, languages: meta.languages, fakeTexts: meta.fakeTexts,
                                createdAt: meta.createdAt)
        let engine = self.engine
        do {
            // Off the actor, so fetch() keeps answering while the engine works.
            let pdf = try await Task.detached(priority: .utility) { try await engine.makeSearchable(input) }.value
            try pdf.write(to: folder.appendingPathComponent("result.pdf"), options: .atomic)
            meta.state = "done"
            log("Text recognition job \(id.prefix(6))… done.")
        } catch {
            meta.state = "failed"
            meta.message = (error as? ProtocolError)?.message ?? "Text recognition failed: \(error.localizedDescription)"
            log("Text recognition job \(id.prefix(6))… failed: \(meta.message ?? "")")
        }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }  // expired meanwhile
        try? writeMeta(meta, id)
        for index in 0..<meta.pages {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("page-\(index + 1).img"))
        }
    }

    private func expireFinished() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for id in names where OcrJobQueue.isValidID(id) && id != running {
            if let meta = readMeta(id), expired(meta) { order.removeAll { $0 == id }; remove(id) }
        }
    }
}
