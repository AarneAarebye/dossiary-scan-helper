import Foundation

actor ScanGate {
    private var busy = false
    func tryBegin() -> Bool { if busy { return false }; busy = true; return true }
    func end() { busy = false }
}

/// Turns a request into a response, following PROTOCOL.md. Knows nothing about sockets.
public final class Router: @unchecked Sendable {
    static let endpoints = ["/health": "GET", "/scanners": "GET", "/scan": "POST", "/pair": "POST"]
    static let needsToken: Set<String> = ["/scanners", "/scan"]

    private let backend: ScannerBackend
    private let pairing: PairingStore
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let gate = ScanGate()

    public init(backend: ScannerBackend, pairing: PairingStore, now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.backend = backend; self.pairing = pairing; self.now = now; self.log = log
    }

    public static func errorBody(_ message: String) -> [String: Any] { ["ok": false, "partial": false, "message": message] }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let origin = request.header("origin")
        guard Origins.allowed(origin) else {
            return .json(403, Router.errorBody("This origin may not use the scan helper."), origin: nil)
        }
        if request.method == "OPTIONS" { return preflight(request, origin: origin) }
        guard let method = Router.endpoints[request.path] else {
            return .json(404, Router.errorBody("Unknown endpoint."), origin: origin)
        }
        guard request.method == method else {
            return .json(405, Router.errorBody("Use \(method) for this endpoint."), origin: origin,
                         extraHeaders: [("Allow", "\(method), OPTIONS")])
        }
        let paired = pairing.isValid(token: Router.bearerToken(request.header("authorization")))
        if Router.needsToken.contains(request.path) && !paired {
            return .json(401, Router.errorBody(
                "This browser isn't paired with the scan helper. Pair it in Dossiary's scan dialog."), origin: origin)
        }
        do {
            switch request.path {
            case "/health":
                return .json(200, ["ok": true, "helper": HelperVersion.helperName, "version": HelperVersion.string,
                                   "protocol": 2, "paired": paired], origin: origin)
            case "/scanners":
                let scanners = await backend.listScanners()
                return .json(200, ["scanners": scanners.map(\.json)], origin: origin)
            case "/pair":
                let (code, client) = try PairingStore.validatePairBody(try request.jsonBody())
                let token = try pairing.pair(code: code, client: client)
                log("Paired a browser\(client.map { " (\($0))" } ?? "").")
                return .json(200, ["ok": true, "token": token], origin: origin)
            default:
                return try await scan(request, origin: origin)
            }
        } catch let error as ProtocolError {
            if error.status >= 500 { log("\(request.path): \(error.status) \(error.message)") }
            return .json(error.status, Router.errorBody(error.message), origin: origin)
        } catch {
            log("\(request.path): unexpected error \(error)")
            return .json(500, Router.errorBody("The scan helper hit an unexpected error: \(error.localizedDescription)"),
                         origin: origin)
        }
    }

    private func scan(_ request: HTTPRequest, origin: String?) async throws -> HTTPResponse {
        let body = try request.jsonBody()
        let (scanner, settings) = try ScanRequestValidator.validate(body, scanners: await backend.listScanners())
        guard await gate.tryBegin() else {
            throw ProtocolError(409, "Another scan is still running. Try again when it has finished.")
        }
        let result: ScanDocuments
        do {
            log("Scanning with \(scanner.name): \(settings.source.rawValue), \(settings.colorMode.rawValue), \(settings.resolution) dpi\(settings.duplex ? ", both sides" : "").")
            result = try await backend.scan(scannerID: scanner.id, settings: settings)
        } catch {
            await gate.end()
            throw error
        }
        await gate.end()
        let payload = try ScanResponse.payload(result, date: now())
        log(payload["message"] as? String ?? "Scan finished.")
        return .json(200, payload, origin: origin)
    }

    private func preflight(_ request: HTTPRequest, origin: String?) -> HTTPResponse {
        var headers: [(String, String)] = []
        if let origin { headers += [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")] }
        headers += [("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
                    ("Access-Control-Allow-Headers", "Content-Type, Authorization"),
                    ("Access-Control-Max-Age", "600")]
        if request.header("access-control-request-private-network") == "true" {
            headers.append(("Access-Control-Allow-Private-Network", "true"))
        }
        return HTTPResponse(status: 204, headers: headers, body: Data())
    }

    static func bearerToken(_ header: String?) -> String? {
        guard let header, header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }
}
