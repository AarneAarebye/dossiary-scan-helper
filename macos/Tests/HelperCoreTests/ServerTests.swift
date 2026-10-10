import Foundation
import Network
import Testing
@testable import HelperCore

@Test func serverAnswersOnLoopback() async throws {
    let router = Router(backend: FakeBackend(), pairing: PairingStore(mode: .fake))
    let server = HTTPServer(port: 0, router: router, log: { _ in })
    try server.start()
    defer { server.stop() }
    let port = try #require(server.boundPort)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
    request.setValue("null", forHTTPHeaderField: "Origin")
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "null")
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["protocol"] as? Int == 2)
}

@Test func secondServerOnTheSamePortFailsToStart() throws {
    let router = Router(backend: FakeBackend(), pairing: PairingStore(mode: .fake))
    let first = HTTPServer(port: 0, router: router, log: { _ in })
    try first.start()
    defer { first.stop() }
    let second = HTTPServer(port: try #require(first.boundPort), router: router, log: { _ in })
    #expect(throws: (any Error).self) { try second.start() }
}

/// Resumes a continuation once, whichever of the answer or the test's own deadline comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

@Test func incompleteRequestIsClosedAfterTheTimeout() async throws {
    let router = Router(backend: FakeBackend(), pairing: PairingStore(mode: .fake))
    let server = HTTPServer(port: 0, router: router, log: { _ in }, requestTimeout: 0.3)
    try server.start()
    defer { server.stop() }
    let port = try #require(server.boundPort)
    let nwPort = try #require(NWEndpoint.Port(rawValue: port))
    let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
    let queue = DispatchQueue(label: "timeout-test")
    // Send half a request head; the server should close the connection without answering.
    let closed: Bool = await withCheckedContinuation { continuation in
        let once = Once(continuation)
        queue.asyncAfter(deadline: .now() + 5) { once.resume(false) }
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data("GET /health HTTP/1.1\r\nHost: x\r\n".utf8), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                    once.resume((data?.isEmpty ?? true) && (isComplete || error != nil))
                }
            }
        }
        connection.start(queue: queue)
    }
    connection.cancel()
    #expect(closed)
}
