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
    private static let maxBytes = 512 * 1024 * 1024
    private static let maxErrorsInARow = 3

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
    private var savedThisSession: Set<String> = []   // keys saved by this run, whatever the ledger managed to write
    private var oversizeLogged: Set<String> = []
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

    private struct Problems { var save: String?; var record: String? }

    /// One pass over every paired server. Never throws; problems are logged and kept in `lastProblem`.
    /// Servers are visited one after the other: a hanging server delays the others by at most its own request timeouts.
    /// A pass cancelled by `stop()` leaves `lastProblem` as it was.
    public func pickUpOnce() async {
        let started = lock.withLock { () -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard started else { return }
        var problems = Problems()
        for server in store.servers {
            if Task.isCancelled { break }
            await pickUp(from: server, problems: &problems)
        }
        let cancelled = Task.isCancelled
        lock.withLock {
            if !cancelled { problem = problems.save ?? problems.record }
            running = false
        }
    }

    private func isValid(id: String) -> Bool {
        id.count >= 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private func known(_ key: String) -> Bool { ledger.contains(key) || lock.withLock { savedThisSession.contains(key) } }

    private func pickUp(from server: RemoteServer, problems: inout Problems) async {
        guard let token = store.token(for: server.id) else { return }
        let link = transport(server)
        let scans: [[String: Any]]
        do {
            let health = try await link.send(RemoteRequest(method: "GET", path: "/health", timeout: 3))
            guard health.status == 200, health.json?["buttonScans"] as? Bool == true else { return }
            let list = try await link.send(RemoteRequest(method: "GET", path: "/button-scans", token: token, timeout: 10))
            guard list.status == 200, let listed = list.json?["scans"] as? [[String: Any]] else {
                if list.status != 401 { log("Button scans: \(server.name) gave status \(list.status) for the list.") }
                return
            }
            scans = listed
        } catch {
            return   // unreachable or changed certificate: RemoteScanners already reports these
        }
        let prefix = "\(server.id)/"
        let listedKeys = Set(scans.compactMap { ($0["id"] as? String).map { prefix + $0 } })
        lock.withLock { firstSeen = firstSeen.filter { !$0.key.hasPrefix(prefix) || listedKeys.contains($0.key) } }

        var errors = 0
        for entry in scans {
            guard let id = entry["id"] as? String, isValid(id: id) else {
                log("Button scans: \(server.name) listed a scan with an unusable id; skipped.")
                continue
            }
            let key = prefix + id
            let name = entry["name"] as? String ?? "scan.pdf"
            let pages = entry["pages"] as? Int ?? 0
            let bytes = entry["bytes"] as? Int
            do {
                if !known(key) {
                    guard readyToTake(key: key, ocr: entry["ocr"] as? String) else { continue }
                    if problems.save != nil { continue }   // the folder is the same for every scan this pass
                    if let bytes, bytes > Self.maxBytes {
                        if lock.withLock({ oversizeLogged.insert(key).inserted }) {
                            log("Button scans: \(server.name) has a scan too large to fetch; skipped.")
                        }
                        continue
                    }
                    let reply = try await link.send(RemoteRequest(method: "GET", path: "/button-scans/\(id)", token: token, timeout: 300))
                    if reply.status == 401 { return }
                    guard reply.status == 200 else {
                        log("Button scans: \(server.name) gave status \(reply.status) for a download.")
                        errors += 1
                        if errors >= Self.maxErrorsInARow { return }
                        continue
                    }
                    guard reply.body.starts(with: Data("%PDF-".utf8)), reply.body.count == bytes else {
                        log("Button scans: a download from \(server.name) was not a complete PDF; will retry.")
                        continue
                    }
                    let file: URL
                    do { file = try folder.save(reply.body, named: name) } catch {
                        let reason = (error as? ButtonScanSaveError)?.reason ?? error.localizedDescription
                        problems.save = "Button scans can't be saved: \(reason)"
                        log(problems.save!)
                        continue
                    }
                    lock.withLock { _ = savedThisSession.insert(key) }
                    do { try ledger.record(key, file: file.lastPathComponent) } catch {
                        problems.record = "Picked-up scans can't be recorded: \(error.localizedDescription)"
                        log(problems.record!)
                    }
                    let scan = PickedUpScan(name: file.lastPathComponent, file: file, pages: pages, server: server.name)
                    lock.withLock { last = scan }
                    log("Button scan saved from \(server.name).")
                    onPickedUp(scan)
                }
                let deletion = try await link.send(RemoteRequest(method: "DELETE", path: "/button-scans/\(id)", token: token, timeout: 30))
                if deletion.status == 401 { return }
                if [200, 204, 404].contains(deletion.status) {
                    lock.withLock { firstSeen[key] = nil }
                    errors = 0
                } else {
                    log("Button scans: \(server.name) refused to delete a saved scan (status \(deletion.status)); will retry.")
                    errors += 1
                    if errors >= Self.maxErrorsInARow { return }
                }
            } catch RemoteError.certificateChanged {
                return
            } catch {
                log("Button scans: \(server.name) could not be reached for a scan; will retry.")
                errors += 1
                if errors >= Self.maxErrorsInARow { return }
            }
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
