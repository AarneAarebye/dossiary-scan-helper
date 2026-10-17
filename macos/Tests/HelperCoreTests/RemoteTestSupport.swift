import Foundation
@testable import HelperCore

/// Answers RemoteRequests from a closure: (status, JSON object) or a thrown error.
final class FakeTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RemoteRequest] = []
    let fingerprint: String
    let handler: @Sendable (RemoteRequest) throws -> (Int, Any)

    init(fingerprint: String = String(repeating: "AB", count: 32),
         handler: @escaping @Sendable (RemoteRequest) throws -> (Int, Any)) {
        self.fingerprint = fingerprint; self.handler = handler
    }

    var sent: [RemoteRequest] { lock.withLock { requests } }

    func send(_ request: RemoteRequest) async throws -> RemoteReply {
        lock.withLock { requests.append(request) }
        let (status, object) = try handler(request)
        return RemoteReply(status: status, body: try JSONSerialization.data(withJSONObject: object), fingerprint: fingerprint)
    }
}

let piScanner: [String: Any] = ["id": "sane:ix500", "name": "ScanSnap iX500", "sources": ["feeder"], "duplex": true,
                                "colorModes": ["color", "gray", "bw"], "resolutions": [150, 300, 600],
                                "extras": ["splitOnBlank", "skipBlankPages"], "ocr": ["languages": ["deu", "eng"]]]

func pairedStore(name: String = "scanner", fingerprint: String = String(repeating: "AB", count: 32)) -> (RemoteServerStore, RemoteServer) {
    let store = RemoteServerStore(fileURL: nil, secrets: MemorySecretStore())
    let server = RemoteServer(name: name, host: "\(name).local", port: 8767, fingerprint: fingerprint)
    try! store.add(server, token: "tok-\(name)")
    return (store, server)
}
