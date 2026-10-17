import Foundation

actor ScanGate {
    private var busy = false
    func tryBegin() -> Bool { if busy { return false }; busy = true; return true }
    func end() { busy = false }
}

/// Turns a request into a response, following PROTOCOL.md. Knows nothing about sockets.
public final class Router: @unchecked Sendable {
    static let endpoints = ["/health": "GET", "/scanners": "GET", "/scan": "POST", "/pair": "POST",
                              "/ocr/*": "GET"]
    static let needsToken: Set<String> = ["/scanners", "/scan", "/ocr/*"]

    /// "/ocr/<job>" is one endpoint, "/ocr/*"; "/ocr", "/ocr/" and deeper paths are unknown.
    static func endpointKey(_ path: String) -> String? {
        if endpoints[path] != nil { return path }
        if path.hasPrefix("/ocr/") {
            let id = path.dropFirst("/ocr/".count)
            if !id.isEmpty && !id.contains("/") { return "/ocr/*" }
        }
        return nil
    }

    private let backend: ScannerBackend
    private let pairing: PairingStore
    private let ocrJobs: OcrJobQueue?
    private let ocrLanguages: [String]
    private let remote: RemoteScanners?
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let gate = ScanGate()

    public init(backend: ScannerBackend, pairing: PairingStore, ocrJobs: OcrJobQueue? = nil,
                ocrLanguages: [String] = [], remote: RemoteScanners? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.backend = backend; self.pairing = pairing; self.ocrJobs = ocrJobs; self.ocrLanguages = ocrLanguages; self.remote = remote; self.now = now; self.log = log
    }

    public static func errorBody(_ message: String) -> [String: Any] { ["ok": false, "partial": false, "message": message] }

    /// DNS-rebinding defence: only loopback names are accepted in Host. A missing Host (HTTP/1.0) is fine.
    static func hostAllowed(_ host: String?) -> Bool {
        guard let host else { return true }
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        var name = h
        if h.hasPrefix("[") {
            guard let close = h.firstIndex(of: "]") else { return false }
            name = String(h[...close])
            let rest = h[h.index(after: close)...]
            if !(rest.isEmpty || rest.hasPrefix(":")) { return false }
        } else if let colon = h.firstIndex(of: ":") {
            name = String(h[..<colon])
        }
        return ["127.0.0.1", "localhost", "[::1]"].contains(name)
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard Router.hostAllowed(request.header("host")) else {
            return .json(403, Router.errorBody("This scan helper only answers requests addressed to localhost."), origin: nil)
        }
        let origin = request.header("origin")
        guard Origins.allowed(origin) else {
            return .json(403, Router.errorBody("This origin may not use the scan helper."), origin: nil)
        }
        if request.method == "OPTIONS" { return preflight(request, origin: origin) }
        guard let key = Router.endpointKey(request.path), let method = Router.endpoints[key] else {
            return .json(404, Router.errorBody("Unknown endpoint."), origin: origin)
        }
        guard request.method == method else {
            return .json(405, Router.errorBody("Use \(method) for this endpoint."), origin: origin,
                         extraHeaders: [("Allow", "\(method), OPTIONS")])
        }
        let paired = pairing.isValid(token: Router.bearerToken(request.header("authorization")))
        if Router.needsToken.contains(key) && !paired {
            return .json(401, Router.errorBody(
                "This browser isn't paired with the scan helper. Pair it in Dossiary's scan dialog."), origin: origin)
        }
        do {
            switch key {
            case "/health":
                return .json(200, ["ok": true, "helper": HelperVersion.helperName, "version": HelperVersion.string,
                                   "protocol": 2, "paired": paired], origin: origin)
            case "/scanners":
                let scanners = await scanners()
                return .json(200, ["scanners": scanners.map(\.json)], origin: origin)
            case "/pair":
                let (code, client) = try PairingStore.validatePairBody(try request.jsonBody())
                let token = try pairing.pair(code: code, client: client)
                log("Paired a browser\(client.map { " (\($0))" } ?? "").")
                return .json(200, ["ok": true, "token": token], origin: origin)
            case "/ocr/*":
                return await ocr(String(request.path.dropFirst("/ocr/".count)), origin: origin)
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
        let (scanner, settings) = try ScanRequestValidator.validate(body, scanners: await scanners())
        if let remote, remote.owns(scanner.id) {
            log("Scanning with \(scanner.name) over the network: \(settings.source.rawValue), \(settings.colorMode.rawValue), \(settings.resolution) dpi\(settings.duplex ? ", both sides" : "")\(settings.ocr ? ", searchable" : "").")
            let (status, payload) = try await remote.scan(scannerID: scanner.id, settings: settings)
            log(payload["message"] as? String ?? "Network scan finished.")
            return .json(status, payload, origin: origin)
        }
        guard await gate.tryBegin() else {
            throw ProtocolError(409, "Another scan is still running. Try again when it has finished.")
        }
        let result: ScanDocuments
        do {
            log("Scanning with \(scanner.name): \(settings.source.rawValue), \(settings.colorMode.rawValue), \(settings.resolution) dpi\(settings.duplex ? ", both sides" : "")\(settings.ocr ? ", searchable" : "").")
            result = try await backend.scan(scannerID: scanner.id, settings: settings)
        } catch {
            await gate.end()
            throw error
        }
        await gate.end()
        let files = try ScanResponse.files(result, date: now())
        var jobs: [String?] = []
        if settings.ocr, let ocrJobs {
            for file in files {
                do {
                    jobs.append(try await ocrJobs.submit(pages: file.pages, name: file.name,
                                                         languages: settings.ocrLanguages, fakeTexts: file.fakeTexts))
                } catch {
                    // The scan succeeded; the file goes out without a job and the client makes it searchable itself.
                    log("Couldn't queue text recognition for \(file.name): \(error.localizedDescription)")
                    jobs.append(nil)
                }
            }
        }
        let payload = ScanResponse.payload(result, files: files, ocrJobs: jobs)
        log(payload["message"] as? String ?? "Scan finished.")
        return .json(200, payload, origin: origin)
    }

    /// The backend's scanners as offered: without a job queue nothing offers `ocr` (fake:ocr included);
    /// with one, scanners without their own list get the engine's languages.
    private func scanners() async -> [ScannerInfo] {
        let local = await backend.listScanners().map { scanner in
            var scanner = scanner
            if ocrJobs == nil { scanner.ocrLanguages = [] }
            else if scanner.ocrLanguages.isEmpty { scanner.ocrLanguages = ocrLanguages }
            return scanner
        }
        return local + (await remote?.listScanners() ?? [])
    }

    private func ocr(_ id: String, origin: String?) async -> HTTPResponse {
        if let remote, remote.isRemoteJob(id) {
            let (status, body) = await remote.fetchOCR(id)
            return .json(status, body, origin: origin)
        }
        let unknown = Router.errorBody("This text recognition job is unknown, already fetched, or expired.")
        guard let ocrJobs else { return .json(404, unknown, origin: origin) }
        switch await ocrJobs.fetch(id) {
        case .pending(let state, let position):
            return .json(202, ["ok": true, "state": state, "position": position], origin: origin)
        case .done(let name, let pages, let pdf):
            return .json(200, ["ok": true, "files": [["name": name, "pages": pages, "data": pdf.base64EncodedString()]]],
                         origin: origin)
        case .failed(let message):
            return .json(500, Router.errorBody(message), origin: origin)
        case .unknown:
            return .json(404, unknown, origin: origin)
        }
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
