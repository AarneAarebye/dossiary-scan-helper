import Foundation
import Network

public struct ServerError: Error, CustomStringConvertible {
    public let description: String
}

/// HTTP/1.1 on 127.0.0.1 only, one request per connection.
public final class HTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let router: Router
    private let log: @Sendable (String) -> Void
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "dossiary-scan-helper.http")
    private var listener: NWListener?

    /// `requestTimeout`: how long a client may take to deliver its complete request after connecting.
    /// It never limits the response, which for a scan can take minutes.
    public init(port: UInt16, router: Router, log: @escaping @Sendable (String) -> Void,
                requestTimeout: TimeInterval = 30) {
        self.port = port; self.router = router; self.log = log; self.requestTimeout = requestTimeout
    }

    public var boundPort: UInt16? { listener?.port?.rawValue }

    /// Binds and waits until listening; throws if the port is taken.
    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        let settled = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: settled.signal()
            case .failed(let error), .waiting(let error): failure.error = error; settled.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        if settled.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw ServerError(description: "The server didn't start within 5 seconds.")
        }
        if let error = failure.error {
            listener.cancel()
            throw ServerError(description: "Port \(port) on 127.0.0.1 isn't available (\(error)). Is the helper already running?")
        }
        listener.stateUpdateHandler = { [log] state in if case .failed(let error) = state { log("Server stopped: \(error)") } }
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private final class FailureBox: @unchecked Sendable { var error: Error? }

    private func accept(_ connection: NWConnection) {
        // Close a connection that hasn't sent a complete request in time. Runs on `queue`,
        // like every receive callback, so it can't race with the request being parsed.
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        connection.start(queue: queue)
        receive(on: connection, parser: HTTPRequestParser(), timeout: timeout)
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var parser = parser
            if let data, !data.isEmpty {
                switch parser.feed(data) {
                case .needMore:
                    break
                case .malformed:
                    timeout.cancel()
                    self.send(.json(400, Router.errorBody("The request isn't valid HTTP."), origin: nil),
                              on: connection, includeBody: true)
                    return
                case .done(let request):
                    timeout.cancel()
                    let router = self.router
                    Task {
                        let response = await router.handle(request)
                        self.send(response, on: connection, includeBody: request.method != "HEAD")
                    }
                    return
                }
            }
            if isComplete || error != nil { timeout.cancel(); connection.cancel(); return }
            self.receive(on: connection, parser: parser, timeout: timeout)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, includeBody: Bool) {
        connection.send(content: response.serialized(includeBody: includeBody), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
