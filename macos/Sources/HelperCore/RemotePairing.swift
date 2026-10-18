import Foundation

public struct RemoteProbe: Equatable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let fingerprint: String
    public init(name: String, host: String, port: Int, fingerprint: String) {
        self.name = name; self.host = host; self.port = port; self.fingerprint = fingerprint
    }
}

public enum PairingFailure: LocalizedError, Equatable, Sendable {
    case notAScanServer, timedOut, conflict, tooMany, refused(String)

    public var errorDescription: String? {
        switch self {
        case .notAScanServer: return "That address isn't a scanix500 network scan server."
        case .timedOut: return "The Scan button wasn't pressed within 2 minutes. Try again."
        case .conflict: return "Another computer tried to pair at the same time. Try again with only one computer."
        case .tooMany: return "Too many pairing requests. Wait a minute, then try again."
        case .refused(let message): return message
        }
    }
}

/// Pairing with a scanix500-server: look at it first (its name and certificate fingerprint, for the person to
/// compare), then pair by the Scan button or a code -- both over a connection pinned to that fingerprint.
public final class RemotePairing: @unchecked Sendable {
    public typealias TransportFactory = @Sendable (_ host: String, _ port: Int, _ pin: String?) -> RemoteTransport
    public static let pollInterval: TimeInterval = 2
    public static let maxPolls = 65

    private let transport: TransportFactory
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(transport: @escaping TransportFactory = { URLSessionRemoteTransport(host: $0, port: $1, pin: $2) },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.transport = transport; self.sleep = sleep
    }

    public func probe(host: String, port: Int) async throws -> RemoteProbe {
        let reply = try await transport(host, port, nil).send(RemoteRequest(method: "GET", path: "/health", timeout: 10))
        guard reply.status == 200, let json = reply.json, json["remote"] as? Bool == true,
              let claimed = json["fingerprint"] as? String, claimed.uppercased() == reply.fingerprint else {
            throw PairingFailure.notAScanServer
        }
        return RemoteProbe(name: json["name"] as? String ?? host, host: host, port: port, fingerprint: reply.fingerprint)
    }

    private func body(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object) }

    public func pairByButton(_ probe: RemoteProbe, client: String) async throws -> String {
        let connection = transport(probe.host, probe.port, probe.fingerprint)
        let start = try await connection.send(RemoteRequest(method: "POST", path: "/pair/button",
                                                            body: body(["client": client]), timeout: 10))
        if start.status == 429 { throw PairingFailure.tooMany }
        guard start.status == 202, let request = start.json?["request"] as? String else {
            throw PairingFailure.refused(start.json?["message"] as? String ?? "The scan server refused to pair.")
        }
        for _ in 0..<Self.maxPolls {
            let reply = try await connection.send(RemoteRequest(method: "GET", path: "/pair/button/\(request)", timeout: 10))
            switch reply.status {
            case 200:
                if let token = reply.json?["token"] as? String { return token }
                throw PairingFailure.refused("The scan server answered without a key.")
            case 202: await sleep(Self.pollInterval)
            case 408: throw PairingFailure.timedOut
            case 409: throw PairingFailure.conflict
            default: throw PairingFailure.refused(reply.json?["message"] as? String ?? "Pairing failed.")
            }
        }
        throw PairingFailure.timedOut
    }

    public func pairByCode(_ probe: RemoteProbe, code: String, client: String) async throws -> String {
        let reply = try await transport(probe.host, probe.port, probe.fingerprint)
            .send(RemoteRequest(method: "POST", path: "/pair", body: body(["code": code, "client": client]), timeout: 10))
        if reply.status == 200, let token = reply.json?["token"] as? String { return token }
        throw PairingFailure.refused(reply.json?["message"] as? String ?? "Pairing failed.")
    }
}
