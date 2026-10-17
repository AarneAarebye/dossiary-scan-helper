import Foundation
import Testing
@testable import HelperCore

private let fp = String(repeating: "AB", count: 32)

private func pairing(_ handler: @escaping @Sendable (RemoteRequest) throws -> (Int, Any)) -> (RemotePairing, FakeTransport) {
    let transport = FakeTransport(fingerprint: fp, handler: handler)
    return (RemotePairing(transport: { _, _, _ in transport }, sleep: { _ in }), transport)
}

private let health: [String: Any] = ["ok": true, "protocol": 2, "remote": true, "fingerprint": fp, "name": "scanner"]

@Test func probeReadsNameAndFingerprint() async throws {
    let (p, _) = pairing { _ in (200, health) }
    let probe = try await p.probe(host: "scanner.local", port: 8767)
    #expect(probe.name == "scanner" && probe.fingerprint == fp && probe.host == "scanner.local")
}

@Test func probeRefusesWhatIsNotAScanServer() async {
    let (p, _) = pairing { _ in (200, ["ok": true, "protocol": 2]) }
    await #expect(throws: PairingFailure.notAScanServer) { try await p.probe(host: "x.local", port: 8767) }
    let (q, _) = pairing { _ in (200, health.merging(["fingerprint": "CD"]) { $1 }) }  // claims another certificate
    await #expect(throws: PairingFailure.notAScanServer) { try await q.probe(host: "x.local", port: 8767) }
}

@Test func buttonPairingWaitsForThePress() async throws {
    let polls = PollCounter()
    let (p, transport) = pairing { request in
        if request.method == "POST" { return (202, ["request": "r1"] as [String: Any]) }
        if polls.next() < 2 { return (202, ["state": "pending"] as [String: Any]) }
        return (200, ["ok": true, "token": "tok"] as [String: Any])
    }
    let probe = RemoteProbe(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp)
    #expect(try await p.pairByButton(probe, client: "Mac") == "tok")
    let first = try #require(transport.sent.first)
    #expect(first.path == "/pair/button")
    #expect(((try? JSONSerialization.jsonObject(with: first.body ?? Data())) as? [String: Any])?["client"] as? String == "Mac")
    #expect(transport.sent.dropFirst().allSatisfy { $0.path == "/pair/button/r1" })
}

@Test func buttonPairingFailures() async {
    let probe = RemoteProbe(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp)
    for (status, failure) in [(408, PairingFailure.timedOut), (409, .conflict)] {
        let (p, _) = pairing { request -> (Int, Any) in
            if request.method == "POST" { return (202, ["request": "r1"] as [String: Any]) }
            return (status, ["ok": false] as [String: Any])
        }
        await #expect(throws: failure) { try await p.pairByButton(probe, client: "Mac") }
    }
    let (busy, _) = pairing { _ in (429, ["ok": false]) }
    await #expect(throws: PairingFailure.tooMany) { try await busy.pairByButton(probe, client: "Mac") }
}

@Test func codePairing() async throws {
    let probe = RemoteProbe(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp)
    let (ok, _) = pairing { _ in (200, ["ok": true, "token": "tok"]) }
    #expect(try await ok.pairByCode(probe, code: "123456", client: "Mac") == "tok")
    let (wrong, _) = pairing { _ in (403, ["ok": false, "message": "That code isn't right."]) }
    await #expect(throws: PairingFailure.refused("That code isn't right.")) {
        try await wrong.pairByCode(probe, code: "000000", client: "Mac")
    }
}

final class PollCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
