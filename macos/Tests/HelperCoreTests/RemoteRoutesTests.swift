import Foundation
import Testing
@testable import HelperCore

// A paired server is reached by its name (scanner.local). Over a split VPN that name does not resolve, so the helper
// remembers the IPv4 address that answered and uses it when the name fails.

private let fp = String(repeating: "AB", count: 32)
private let home = "192.168.65.78"

/// Which hosts answer, with which reported address, and in which order they were asked.
private final class FakeNetwork: @unchecked Sendable {
    enum Behaviour { case answers(address: String?), unreachable, otherCertificate }
    private let lock = NSLock()
    private var behaviours: [String: Behaviour]
    private var asked: [String] = []

    init(_ behaviours: [String: Behaviour]) { self.behaviours = behaviours }
    var calls: [String] { lock.withLock { asked } }
    func set(_ host: String, _ behaviour: Behaviour) { lock.withLock { behaviours[host] = behaviour } }

    func make(_ host: String) -> RemoteTransport {
        FakeHost(host: host, network: self)
    }

    fileprivate func answer(_ host: String) throws -> RemoteReply {
        let behaviour = lock.withLock { () -> Behaviour in
            asked.append(host)
            return behaviours[host] ?? .unreachable
        }
        switch behaviour {
        case .answers(let address):
            return RemoteReply(status: 200, body: Data("{}".utf8), fingerprint: fp, address: address)
        case .unreachable:
            throw RemoteError.unreachable("no route to \(host)")
        case .otherCertificate:
            throw RemoteError.certificateChanged(seen: "CD")
        }
    }
}

private struct FakeHost: RemoteTransport {
    let host: String
    let network: FakeNetwork
    func send(_ request: RemoteRequest) async throws -> RemoteReply { try network.answer(host) }
}

private func setUp(lastAddress: String? = nil, _ behaviours: [String: FakeNetwork.Behaviour])
    -> (RemoteRoutes, RemoteServerStore, RemoteServer, FakeNetwork) {
    let (store, server) = pairedStore()
    if let lastAddress { try! store.updateAddress(id: server.id, to: lastAddress) }
    let network = FakeNetwork(behaviours)
    let routes = RemoteRoutes(store: store, make: { host, _ in network.make(host) })
    return (routes, store, server, network)
}

private let get = RemoteRequest(method: "GET", path: "/scanners", token: "tok", timeout: 3)

@Test func learnsTheAddressThatAnsweredOverTheName() async throws {
    let (routes, store, server, _) = setUp(["scanner.local": .answers(address: home)])
    _ = try await routes.transport(for: server).send(get)
    #expect(store.servers.first?.lastAddress == home)
    #expect(store.token(for: server.id) == "tok-scanner")
}

@Test func doesNotRememberIPv6OrTheNameItselfOrNothing() async throws {
    for reported in ["fe80::1%en0", "2001:db8::1", "scanner.local", "", nil] as [String?] {
        let (routes, store, server, _) = setUp(["scanner.local": .answers(address: reported)])
        _ = try await routes.transport(for: server).send(get)
        #expect(store.servers.first?.lastAddress == nil, "reported \(reported ?? "nil")")
    }
}

@Test func aServerPairedByAddressRemembersNothingNew() async throws {
    let store = RemoteServerStore(fileURL: nil, secrets: MemorySecretStore())
    let server = RemoteServer(name: "scanner", host: home, port: 8767, fingerprint: fp)
    try store.add(server, token: "t")
    let network = FakeNetwork([home: .answers(address: home)])
    let routes = RemoteRoutes(store: store, make: { host, _ in network.make(host) })
    _ = try await routes.transport(for: server).send(get)
    #expect(store.servers.first?.lastAddress == nil)
}

@Test func fallsBackToTheRememberedAddressWhenTheNameFails() async throws {
    let (routes, _, server, network) = setUp(lastAddress: home, ["scanner.local": .unreachable, home: .answers(address: home)])
    let reply = try await routes.transport(for: server).send(get)
    #expect(reply.status == 200)
    #expect(network.calls == ["scanner.local", home])
}

@Test func triesTheRouteThatWorkedLastFirst() async throws {
    let (routes, _, server, network) = setUp(lastAddress: home, ["scanner.local": .unreachable, home: .answers(address: home)])
    _ = try await routes.transport(for: server).send(get)
    _ = try await routes.transport(for: server).send(get)
    #expect(network.calls == ["scanner.local", home, home])
}

@Test func returnsToTheNameWhenTheAddressGoesStale() async throws {
    let (routes, _, server, network) = setUp(lastAddress: home, ["scanner.local": .unreachable, home: .answers(address: home)])
    _ = try await routes.transport(for: server).send(get)           // away: the address works
    network.set("scanner.local", .answers(address: "192.168.65.99"))
    network.set(home, .unreachable)                                  // back home, the Pi has a new address
    _ = try await routes.transport(for: server).send(get)
    _ = try await routes.transport(for: server).send(get)
    #expect(network.calls == ["scanner.local", home, home, "scanner.local", "scanner.local"])
}

@Test func anotherDeviceAtTheRememberedAddressIsJustStale() async throws {
    let (routes, store, server, network) = setUp(lastAddress: home, ["scanner.local": .unreachable, home: .otherCertificate])
    await #expect(throws: RemoteError.unreachable("no route to scanner.local")) {
        try await routes.transport(for: server).send(get)
    }
    #expect(network.calls == ["scanner.local", home])
    #expect(store.servers.first?.lastAddress == home)   // kept: the Pi may be back at it later
}

@Test func aChangedCertificateOnTheNameIsStillReportedAndNeverRetriedByAddress() async throws {
    let (routes, _, server, network) = setUp(lastAddress: home, ["scanner.local": .otherCertificate, home: .answers(address: home)])
    await #expect(throws: RemoteError.certificateChanged(seen: "CD")) {
        try await routes.transport(for: server).send(get)
    }
    #expect(network.calls == ["scanner.local"])
}

@Test func withoutARememberedAddressAFailingNameIsJustUnreachable() async throws {
    let (routes, _, server, network) = setUp(["scanner.local": .unreachable])
    await #expect(throws: RemoteError.unreachable("no route to scanner.local")) {
        try await routes.transport(for: server).send(get)
    }
    #expect(network.calls == ["scanner.local"])
}

@Test func theRememberedAddressSurvivesARestartAndOldFilesStillLoad() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("remote-servers.json")
    let secrets = MemorySecretStore()
    let store = RemoteServerStore(fileURL: file, secrets: secrets)
    let server = RemoteServer(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp)
    try store.add(server, token: "t")
    try store.updateAddress(id: server.id, to: home)
    #expect(RemoteServerStore(fileURL: file, secrets: secrets).servers.first?.lastAddress == home)

    let old = #"[{"fingerprint":"\#(fp)","host":"scanner.local","id":"\#(server.id)","name":"scanner","port":8767}]"#
    try Data(old.utf8).write(to: file)
    let loaded = RemoteServerStore(fileURL: file, secrets: secrets).servers
    #expect(loaded.count == 1 && loaded.first?.lastAddress == nil && loaded.first?.host == "scanner.local")
}

@Test func updatingAnUnknownServerIsIgnored() throws {
    let store = RemoteServerStore(fileURL: nil, secrets: MemorySecretStore())
    try store.updateAddress(id: "nope", to: home)
    #expect(store.servers.isEmpty)
}
