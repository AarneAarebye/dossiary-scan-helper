import Foundation

public enum RemoteStatus: Equatable, Sendable { case connected, needsPairing, unreachable, certificateChanged }

/// The paired scanix500-servers' scanners: listed beside the helper's own and used through the server, which
/// already speaks protocol version 2 -- so answers are passed on, only ids and job ids renamed.
public final class RemoteScanners: @unchecked Sendable {
    public typealias TransportFactory = @Sendable (RemoteServer) -> RemoteTransport
    public static let idPrefix = "remote:"
    public static let jobPrefix = "remote."

    private let store: RemoteServerStore
    private let transport: TransportFactory
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var status: [String: RemoteStatus] = [:]

    public init(store: RemoteServerStore,
                transport: @escaping TransportFactory = { URLSessionRemoteTransport(host: $0.host, port: $0.port, pin: $0.fingerprint) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store; self.transport = transport; self.log = log
    }

    public var servers: [RemoteServer] { store.servers }
    public var statuses: [String: RemoteStatus] { lock.withLock { status } }

    private func setStatus(_ value: RemoteStatus, _ server: RemoteServer) {
        let changed = lock.withLock { () -> Bool in
            defer { status[server.id] = value }
            return status[server.id] != value
        }
        if changed { log("Network scanner \(server.name) (\(server.host)): \(value).") }
    }

    public func owns(_ scannerID: String) -> Bool { scannerID.hasPrefix(Self.idPrefix) }
    public func isRemoteJob(_ id: String) -> Bool { id.hasPrefix(Self.jobPrefix) }

    public func listScanners() async -> [ScannerInfo] {
        await withTaskGroup(of: [ScannerInfo].self) { group in
            for server in store.servers { group.addTask { await self.list(server) } }
            var all: [ScannerInfo] = []
            for await part in group { all += part }
            return all.sorted { $0.name < $1.name }
        }
    }

    private func list(_ server: RemoteServer) async -> [ScannerInfo] {
        guard let token = store.token(for: server.id) else { setStatus(.needsPairing, server); return [] }
        do {
            let reply = try await transport(server).send(RemoteRequest(method: "GET", path: "/scanners", token: token, timeout: 3))
            if reply.status == 401 { setStatus(.needsPairing, server); return [] }
            guard reply.status == 200, let list = reply.json?["scanners"] as? [[String: Any]] else {
                setStatus(.unreachable, server); return []
            }
            setStatus(.connected, server)
            return list.compactMap(ScannerInfo.init(json:)).map { scanner in
                var scanner = scanner
                scanner.id = "\(Self.idPrefix)\(server.id):\(scanner.id)"
                scanner.name = "\(scanner.name) (\(server.name))"
                return scanner
            }
        } catch RemoteError.certificateChanged {
            setStatus(.certificateChanged, server); return []
        } catch {
            setStatus(.unreachable, server); return []
        }
    }

    /// "remote:<server>:<scanner>" → the server and its own scanner id.
    private func locate(_ scannerID: String) -> (RemoteServer, String)? {
        let rest = scannerID.dropFirst(Self.idPrefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let serverID = String(rest[..<colon]), remoteID = String(rest[rest.index(after: colon)...])
        guard let server = store.servers.first(where: { $0.id == serverID }) else { return nil }
        return (server, remoteID)
    }

    private static func needsPairing(_ server: RemoteServer) -> ProtocolError {
        ProtocolError(503, "\(server.name) needs to be paired again: choose “Add network scanner…” in Dossiary Scan Helper.")
    }

    public func scan(scannerID: String, settings: ScanSettings) async throws -> (Int, [String: Any]) {
        guard let (server, remoteID) = locate(scannerID), let token = store.token(for: server.id) else {
            throw ProtocolError(503, "This network scanner isn't set up in Dossiary Scan Helper any more.")
        }
        var body: [String: Any] = ["scanner": remoteID, "source": settings.source.rawValue, "duplex": settings.duplex,
                                   "colorMode": settings.colorMode.rawValue, "resolution": settings.resolution,
                                   "extras": settings.extras]
        if settings.ocr { body["ocr"] = true; body["ocrLanguages"] = settings.ocrLanguages }
        if settings.format != "pdf" { body["format"] = settings.format }
        if let area = settings.area { body["area"] = area }
        let reply: RemoteReply
        do {
            reply = try await transport(server).send(RemoteRequest(method: "POST", path: "/scan", token: token,
                                                                   body: try JSONSerialization.data(withJSONObject: body),
                                                                   timeout: 1800))
        } catch let error as RemoteError {
            throw ProtocolError(503, "\(server.name): \(error.errorDescription ?? "can't be reached.")")
        }
        if reply.status == 401 { throw Self.needsPairing(server) }
        guard var object = reply.json else {
            throw ProtocolError(500, "\(server.name) gave an answer the scan helper couldn't read.")
        }
        if let files = object["files"] as? [[String: Any]] {
            object["files"] = files.map { file -> [String: Any] in
                var file = file
                if let job = file["ocrJob"] as? String { file["ocrJob"] = "\(Self.jobPrefix)\(server.id).\(job)" }
                return file
            }
        }
        return (reply.status, object)
    }

    public func fetchOCR(_ id: String) async -> (Int, [String: Any]) {
        let unknown = (404, Router.errorBody("This text recognition job is unknown, already fetched, or expired."))
        let rest = id.dropFirst(Self.jobPrefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return unknown }
        let serverID = String(rest[..<dot]), job = String(rest[rest.index(after: dot)...])
        guard !job.isEmpty, let server = store.servers.first(where: { $0.id == serverID }),
              let token = store.token(for: server.id) else { return unknown }
        do {
            let reply = try await transport(server).send(RemoteRequest(method: "GET", path: "/ocr/\(job)", token: token, timeout: 30))
            if reply.status == 401 { return (503, Router.errorBody(Self.needsPairing(server).message)) }
            return (reply.status, reply.json ?? Router.errorBody("\(server.name) gave an answer the scan helper couldn't read."))
        } catch {
            // 503 keeps Dossiary polling; after 10 minutes it makes the document searchable itself.
            return (503, Router.errorBody("\(server.name) can't be reached right now."))
        }
    }
}
