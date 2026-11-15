import Foundation

/// How a paired server is reached. Its name (`scanner.local`) comes from Bonjour, which does not cross a split VPN;
/// the IPv4 address that answered over the name is remembered and used when the name fails. The pinned certificate
/// is checked on every attempt, so a stale address that now belongs to another device is refused, never trusted.
public final class RemoteRoutes: @unchecked Sendable {
    public typealias Make = @Sendable (_ host: String, _ server: RemoteServer) -> RemoteTransport

    fileprivate let store: RemoteServerStore
    fileprivate let make: Make
    private let lock = NSLock()
    private var preferAddress: Set<String> = []   // server ids whose remembered address answered last

    public init(store: RemoteServerStore,
                make: @escaping Make = { host, server in URLSessionRemoteTransport(host: host, port: server.port, pin: server.fingerprint) }) {
        self.store = store; self.make = make
    }

    public func transport(for server: RemoteServer) -> RemoteTransport { RoutedTransport(server: server, routes: self) }

    fileprivate func prefersAddress(_ id: String) -> Bool { lock.withLock { preferAddress.contains(id) } }

    fileprivate func setPrefersAddress(_ on: Bool, _ id: String) {
        lock.withLock { if on { preferAddress.insert(id) } else { preferAddress.remove(id) } }
    }

    /// Only a plain IPv4 address is worth keeping: IPv6 link-local addresses don't leave the local network.
    static func isRememberable(_ address: String, host: String) -> Bool {
        var addr = in_addr()
        guard address != host, inet_pton(AF_INET, address, &addr) == 1 else { return false }
        return !address.hasPrefix("127.") && !address.hasPrefix("169.254.") && address != "0.0.0.0"
    }
}

private struct RoutedTransport: RemoteTransport {
    let server: RemoteServer
    let routes: RemoteRoutes

    func send(_ request: RemoteRequest) async throws -> RemoteReply {
        let current = routes.store.servers.first { $0.id == server.id } ?? server
        guard let address = current.lastAddress, address != current.host else { return try await viaName(request) }
        let order = routes.prefersAddress(server.id) ? [true, false] : [false, true]   // true = the remembered address
        var nameError: Error?
        var addressError: Error?
        for useAddress in order {
            do {
                if useAddress {
                    let reply = try await routes.make(address, current).send(request)
                    routes.setPrefersAddress(true, server.id)
                    return reply
                }
                let reply = try await viaName(request, current: current)
                routes.setPrefersAddress(false, server.id)
                return reply
            } catch RemoteError.certificateChanged(let seen) where !useAddress {
                throw RemoteError.certificateChanged(seen: seen)   // the name's certificate changed: a real alarm
            } catch {
                if useAddress { addressError = error } else { nameError = error }   // a stale address is just a failed try
            }
        }
        throw nameError ?? addressError ?? RemoteError.unreachable("no route")
    }

    private func viaName(_ request: RemoteRequest, current: RemoteServer? = nil) async throws -> RemoteReply {
        let current = current ?? server
        let reply = try await routes.make(current.host, current).send(request)
        if let seen = reply.address, RemoteRoutes.isRememberable(seen, host: current.host) {
            try? routes.store.updateAddress(id: server.id, to: seen)
        }
        return reply
    }
}
