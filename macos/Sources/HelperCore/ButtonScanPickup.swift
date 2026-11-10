import Foundation

public enum ButtonScanProblem: Equatable, Sendable {
    case cannotSave(reason: String)
    case cannotRecord(reason: String)
    case tooLarge(server: String)

    /// The English text, for the log.
    public var logText: String {
        switch self {
        case .cannotSave(let reason): return "Button scans can't be saved: \(reason)"
        case .cannotRecord(let reason): return "Picked-up scans can't be recorded: \(reason)"
        case .tooLarge(let server): return "\(server) has a button scan that is too large to pick up."
        }
    }
}

/// The scanner button a server reports on /health.
public enum ButtonPress: String, Sendable { case color, bw, custom, finish }

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
    /// How long a scan whose text recognition still says "pending" is waited for. A Pi needs a good while for a
    /// 20-40 page batch, and a PDF taken too early has no text, so this is generous (raised from 5 minutes).
    private static let pendingGrace: TimeInterval = 30 * 60
    private static let maxBytes = 512 * 1024 * 1024
    private static let maxErrorsInARow = 3

    private let store: RemoteServerStore
    private let folder: ButtonScanFolder
    private let ledger: PickedUpLedger
    private let transport: RemoteScanners.TransportFactory
    private let clock: @Sendable () -> Date
    private var handler: @Sendable (PickedUpScan) -> Void
    private var pressHandler: @Sendable (ButtonPress) -> Void
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var running = false
    private var lastSeq: [String: Int] = [:]   // per server id; absent = no baseline yet
    private var firstSeen: [String: Date] = [:]
    private var savedThisSession: Set<String> = []   // keys saved by this run, whatever the ledger managed to write
    private var oversizeLogged: Set<String> = []
    private var problem: ButtonScanProblem?
    private var incompleteLogged: Set<String> = []
    private var last: PickedUpScan?
    private var loop: Task<Void, Never>?

    public init(store: RemoteServerStore, folder: ButtonScanFolder, ledger: PickedUpLedger,
                transport: @escaping RemoteScanners.TransportFactory = { URLSessionRemoteTransport(host: $0.host, port: $0.port, pin: $0.fingerprint) },
                clock: @escaping @Sendable () -> Date = Date.init,
                onPickedUp: @escaping @Sendable (PickedUpScan) -> Void = { _ in },
                onButtonPress: @escaping @Sendable (ButtonPress) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store; self.folder = folder; self.ledger = ledger; self.transport = transport
        self.clock = clock; self.handler = onPickedUp; self.pressHandler = onButtonPress; self.log = log
    }

    /// Called after each scan is saved. Settable after init, for a notifier created later.
    public var onPickedUp: @Sendable (PickedUpScan) -> Void {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// Called when a paired server reports a new button press. Settable after init, for a player created later.
    public var onButtonPress: @Sendable (ButtonPress) -> Void {
        get { lock.withLock { pressHandler } }
        set { lock.withLock { pressHandler = newValue } }
    }

    public var lastProblem: ButtonScanProblem? { lock.withLock { problem } }
    public var lastScan: PickedUpScan? { lock.withLock { last } }

    public func start(interval: TimeInterval = 1) {
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

    private struct Problems { var save: ButtonScanProblem?; var record: ButtonScanProblem?; var large: ButtonScanProblem? }

    /// One pass over every paired server. Never throws; problems are logged and kept in `lastProblem`.
    /// Health checks run concurrently; listing, downloading and deleting go one server after the other.
    /// A pass cancelled by `stop()` leaves `lastProblem` as it was.
    public func pickUpOnce() async {
        let started = lock.withLock { () -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard started else { return }
        var problems = Problems()
        // Health checks (and press detection) run for all servers at once, so a slow server never delays another's sound.
        let ready = await withTaskGroup(of: (RemoteServer, String, any RemoteTransport)?.self) { group in
            for server in store.servers {
                group.addTask { await self.checkHealth(of: server) }
            }
            var found: [(RemoteServer, String, any RemoteTransport)] = []
            for await item in group { if let item { found.append(item) } }
            return found
        }
        for server in store.servers {
            if Task.isCancelled { break }
            guard let item = ready.first(where: { $0.0.id == server.id }) else { continue }
            await pickUp(from: server, token: item.1, link: item.2, problems: &problems)
        }
        let cancelled = Task.isCancelled
        lock.withLock {
            if !cancelled { problem = problems.save ?? problems.record ?? problems.large }
            running = false
        }
    }

    private func isValid(id: String) -> Bool {
        id.count >= 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private func known(_ key: String) -> Bool { ledger.contains(key) || lock.withLock { savedThisSession.contains(key) } }

    /// Remembers the server's press counter; a change after the first value is a press.
    private func noteButtonEvent(_ value: Any?, server: RemoteServer) {
        guard let event = value as? [String: Any], let number = event["seq"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), CFNumberIsFloatType(number) == false else { return }
        let seq = number.intValue
        let button = (event["button"] as? String).flatMap(ButtonPress.init(rawValue:))
        let callback: (@Sendable (ButtonPress) -> Void)? = lock.withLock {
            let previous = lastSeq[server.id]
            lastSeq[server.id] = seq
            guard let previous, previous != seq, button != nil else { return nil }
            return pressHandler
        }
        if let callback, let button { callback(button) }
    }

    /// The /health step for one server: sends the token, notes the button event, and returns what the pickup needs
    /// when the server offers button scans.
    private func checkHealth(of server: RemoteServer) async -> (RemoteServer, String, any RemoteTransport)? {
        guard let token = store.token(for: server.id) else { return nil }
        let link = transport(server)
        let health: RemoteReply
        do {
            health = try await link.send(RemoteRequest(method: "GET", path: "/health", token: token, timeout: 3))
        } catch {
            lock.withLock { lastSeq[server.id] = nil }   // after a reconnect the next value is a baseline again
            return nil   // unreachable or changed certificate: RemoteScanners already reports these
        }
        guard health.status == 200, health.json?["buttonScans"] as? Bool == true else { return nil }
        noteButtonEvent(health.json?["buttonEvent"], server: server)
        return (server, token, link)
    }

    private func pickUp(from server: RemoteServer, token: String, link: any RemoteTransport, problems: inout Problems) async {
        let scans: [[String: Any]]
        do {
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
            if Task.isCancelled { return }
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
                    guard let bytes else {   // the list must say how big the PDF is
                        if lock.withLock({ incompleteLogged.insert(key).inserted }) {
                            log("Button scans: \(server.name) listed a scan without a size; skipped.")
                        }
                        continue
                    }
                    if bytes > Self.maxBytes {
                        let problem = ButtonScanProblem.tooLarge(server: server.name)
                        problems.large = problem
                        if lock.withLock({ oversizeLogged.insert(key).inserted }) { log(problem.logText) }
                        continue
                    }
                    let reply = try await link.send(RemoteRequest(method: "GET", path: "/button-scans/\(id)", token: token, timeout: 300))
                    if reply.status == 401 { return }
                    if reply.status == 404 {   // another client took it
                        lock.withLock { firstSeen[key] = nil }
                        continue
                    }
                    guard reply.status == 200 else {
                        log("Button scans: \(server.name) gave status \(reply.status) for a download.")
                        errors += 1
                        if errors >= Self.maxErrorsInARow { return }
                        continue
                    }
                    guard reply.body.starts(with: Data("%PDF-".utf8)), reply.body.count == bytes else {
                        if lock.withLock({ incompleteLogged.insert(key).inserted }) {
                            log("Button scans: a download from \(server.name) was not a complete PDF; will retry.")
                        }
                        errors += 1
                        if errors >= Self.maxErrorsInARow { return }
                        continue
                    }
                    let file: URL
                    do { file = try folder.save(reply.body, named: name) } catch {
                        let reason = (error as? ButtonScanSaveError)?.reason ?? error.localizedDescription
                        problems.save = .cannotSave(reason: reason)
                        log(problems.save!.logText)
                        continue
                    }
                    lock.withLock { _ = savedThisSession.insert(key) }
                    do { try ledger.record(key, file: file.lastPathComponent) } catch {
                        problems.record = .cannotRecord(reason: error.localizedDescription)
                        log(problems.record!.logText)
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
                if Task.isCancelled { return }
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
