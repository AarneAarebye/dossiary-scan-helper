import Foundation

public struct PickedUpScan: Equatable, Sendable {
    public let name: String
    public let file: URL
    public let pages: Int
    public let server: String
    public init(name: String, file: URL, pages: Int, server: String) {
        self.name = name; self.file = file; self.pages = pages; self.server = server
    }
}

/// Fetches finished button-scan PDFs from the paired scan servers, saves them, and only then deletes them on the
/// server. A failed save or delete never loses a scan: it stays on the server for a later pass.
public final class ButtonScanPickup: @unchecked Sendable {
    private static let pendingGrace: TimeInterval = 5 * 60

    private let store: RemoteServerStore
    private let folder: ButtonScanFolder
    private let ledger: PickedUpLedger
    private let transport: RemoteScanners.TransportFactory
    private let clock: @Sendable () -> Date
    private let onPickedUp: @Sendable (PickedUpScan) -> Void
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var running = false
    private var firstSeen: [String: Date] = [:]
    private var problem: String?
    private var last: PickedUpScan?
    private var loop: Task<Void, Never>?

    public init(store: RemoteServerStore, folder: ButtonScanFolder, ledger: PickedUpLedger,
                transport: @escaping RemoteScanners.TransportFactory = { URLSessionRemoteTransport(host: $0.host, port: $0.port, pin: $0.fingerprint) },
                clock: @escaping @Sendable () -> Date = Date.init,
                onPickedUp: @escaping @Sendable (PickedUpScan) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store; self.folder = folder; self.ledger = ledger; self.transport = transport
        self.clock = clock; self.onPickedUp = onPickedUp; self.log = log
    }

    public var lastProblem: String? { lock.withLock { problem } }
    public var lastScan: PickedUpScan? { lock.withLock { last } }

    public func start(interval: TimeInterval = 5) {
        lock.withLock {
            loop?.cancel()
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.pickUpOnce()
                    try? await Task.sleep(nanoseconds: UInt64(max(interval, 0.001) * 1_000_000_000))
                }
            }
        }
    }

    public func stop() {
        lock.withLock { loop?.cancel(); loop = nil }
    }

    /// One pass over every paired server. Never throws; problems are logged and kept in `lastProblem`.
    public func pickUpOnce() async {
        let started = lock.withLock { () -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard started else { return }
        var saveProblem: String?
        for server in store.servers {
            if let found = await pickUp(from: server) { saveProblem = saveProblem ?? found }
        }
        lock.withLock { problem = saveProblem; running = false }
    }

    private func isValid(id: String) -> Bool {
        id.count >= 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Returns a "can't be saved" message when the folder could not be written.
    private func pickUp(from server: RemoteServer) async -> String? {
        guard let token = store.token(for: server.id) else { return nil }
        let link = transport(server)
        do {
            let health = try await link.send(RemoteRequest(method: "GET", path: "/health", timeout: 3))
            guard health.status == 200, health.json?["buttonScans"] as? Bool == true else { return nil }
            let list = try await link.send(RemoteRequest(method: "GET", path: "/button-scans", token: token, timeout: 10))
            guard list.status == 200, let scans = list.json?["scans"] as? [[String: Any]] else {
                if list.status != 401 { log("Button scans: \(server.name) gave status \(list.status) for the list.") }
                return nil
            }
            var saveProblem: String?
            for entry in scans {
                guard let id = entry["id"] as? String, isValid(id: id) else {
                    log("Button scans: \(server.name) listed a scan with an unusable id; skipped.")
                    continue
                }
                let name = entry["name"] as? String ?? "scan.pdf"
                let pages = entry["pages"] as? Int ?? 0
                let key = "\(server.id)/\(id)"
                if !ledger.contains(id) {
                    guard readyToTake(key: key, ocr: entry["ocr"] as? String) else { continue }
                    if saveProblem != nil { continue }   // the folder is the same for every scan this pass
                    let reply = try await link.send(RemoteRequest(method: "GET", path: "/button-scans/\(id)", token: token, timeout: 300))
                    guard reply.status == 200 else {
                        log("Button scans: \(server.name) gave status \(reply.status) for a download.")
                        continue
                    }
                    guard reply.body.starts(with: Data("%PDF-".utf8)), reply.body.count == entry["bytes"] as? Int else {
                        log("Button scans: a download from \(server.name) was not a complete PDF; will retry.")
                        continue
                    }
                    do {
                        let file = try folder.save(reply.body, named: name)
                        try ledger.record(id, file: file.lastPathComponent)
                        let scan = PickedUpScan(name: file.lastPathComponent, file: file, pages: pages, server: server.name)
                        lock.withLock { last = scan }
                        log("Button scan saved from \(server.name).")
                        onPickedUp(scan)
                    } catch {
                        let reason = (error as? ButtonScanSaveError)?.reason ?? error.localizedDescription
                        saveProblem = "Button scans can't be saved: \(reason)"
                        log(saveProblem!)
                        continue
                    }
                }
                let deletion = try await link.send(RemoteRequest(method: "DELETE", path: "/button-scans/\(id)", token: token, timeout: 30))
                if [200, 204, 404].contains(deletion.status) {
                    lock.withLock { firstSeen[key] = nil }
                } else {
                    log("Button scans: \(server.name) refused to delete a saved scan (status \(deletion.status)); will retry.")
                }
            }
            return saveProblem
        } catch {
            return nil   // unreachable or changed certificate: RemoteScanners already reports these
        }
    }

    private func readyToTake(key: String, ocr: String?) -> Bool {
        if ocr == "done" || ocr == "failed" { return true }
        let now = clock()
        return lock.withLock {
            let seen = firstSeen[key] ?? now
            firstSeen[key] = seen
            return now.timeIntervalSince(seen) > Self.pendingGrace
        }
    }
}
