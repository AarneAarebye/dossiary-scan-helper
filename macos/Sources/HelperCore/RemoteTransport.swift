import CryptoKit
import Foundation
import Security

/// A scanix500-server's certificate fingerprint: SHA-256 of the certificate's DER bytes, uppercase hex.
/// The helper pins it when it pairs and refuses any other certificate afterwards.
public enum RemoteFingerprint {
    public static func sha256Hex(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    /// The first 128 bits in 8 groups of 4, the way `scanix500-server status` prints it.
    public static func display(_ hex: String) -> String {
        let head = Array(hex.prefix(32))
        return stride(from: 0, to: head.count, by: 4)
            .map { String(head[$0..<min($0 + 4, head.count)]) }
            .joined(separator: "-")
    }

    /// No pin yet (while pairing, the person compares the fingerprint) or exactly the pinned one.
    public static func accepts(observed: String, pin: String?) -> Bool { pin == nil || pin == observed }
}

public enum RemoteError: LocalizedError, Equatable, Sendable {
    case unreachable(String)
    case certificateChanged(seen: String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return "The network scanner can't be reached (\(detail))."
        case .certificateChanged(let seen):
            return "The network scanner presented a different certificate (\(RemoteFingerprint.display(seen))) from the one used "
                + "during pairing. If the server was reinstalled, remove the scanner from Dossiary Scan Helper and add it again."
        }
    }
}

public struct RemoteRequest: Sendable {
    public var method: String
    public var path: String
    public var token: String?
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, path: String, token: String? = nil, body: Data? = nil, timeout: TimeInterval) {
        self.method = method; self.path = path; self.token = token; self.body = body; self.timeout = timeout
    }
}

public struct RemoteReply: Sendable {
    public var status: Int
    public var body: Data
    /// The certificate fingerprint this answer came with.
    public var fingerprint: String

    public init(status: Int, body: Data, fingerprint: String) {
        self.status = status; self.body = body; self.fingerprint = fingerprint
    }

    public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

public protocol RemoteTransport: Sendable {
    func send(_ request: RemoteRequest) async throws -> RemoteReply
}

/// Accepts the server's self-signed certificate only by its pinned fingerprint (or, with no pin, records it).
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pin: String?
    private let lock = NSLock()
    private var seen: String?

    init(pin: String?) { self.pin = pin }

    var observed: String? { lock.withLock { seen } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = RemoteFingerprint.sha256Hex(SecCertificateCopyData(leaf) as Data)
        lock.withLock { seen = fingerprint }
        if RemoteFingerprint.accepts(observed: fingerprint, pin: pin) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public final class URLSessionRemoteTransport: RemoteTransport, @unchecked Sendable {
    private let base: URL
    private let delegate: PinningDelegate
    private let session: URLSession

    public init(host: String, port: Int, pin: String?) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        base = components.url ?? URL(string: "https://invalid.invalid")!
        delegate = PinningDelegate(pin: pin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: RemoteRequest) async throws -> RemoteReply {
        guard let url = URL(string: request.path, relativeTo: base) else { throw RemoteError.unreachable("bad address") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        if let token = request.token { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return RemoteReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data,
                               fingerprint: delegate.observed ?? "")
        } catch {
            if let seen = delegate.observed, !RemoteFingerprint.accepts(observed: seen, pin: delegate.pin) {
                throw RemoteError.certificateChanged(seen: seen)
            }
            throw RemoteError.unreachable(error.localizedDescription)
        }
    }
}
