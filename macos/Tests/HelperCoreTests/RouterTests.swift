import Foundation
import Testing
@testable import HelperCore

private func makeRouter(backend: ScannerBackend = FakeBackend()) -> (Router, String) {
    let pairing = PairingStore(mode: .fake)
    let token = try! pairing.pair(code: "000000", client: nil)
    return (Router(backend: backend, pairing: pairing), token)
}

private func req(_ method: String, _ path: String, origin: String? = nil, token: String? = nil,
                 body: String? = nil, headers: [String: String] = [:]) -> HTTPRequest {
    var all = headers
    if let origin { all["Origin"] = origin }
    if let token { all["Authorization"] = "Bearer \(token)" }
    return HTTPRequest(method: method, path: path, headers: all, body: Data((body ?? "").utf8), bodyError: nil)
}

private func object(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
}

@Test func originRules() {
    for origin in [nil, "null", "http://localhost", "http://127.0.0.1", "http://localhost:8080", "http://127.0.0.1:65535"] {
        #expect(Origins.allowed(origin), "\(origin ?? "none")")
    }
    for origin in ["https://localhost", "http://localhost:0", "http://localhost:65536", "http://evil.example",
                   "http://localhost.evil.example", "http://127.0.0.1:80/x", ""] {
        #expect(!Origins.allowed(origin), "\(origin)")
    }
}

@Test func otherOriginsGet403WithoutCORS() async {
    let (router, token) = makeRouter()
    for request in [req("GET", "/health", origin: "https://evil.example"),
                    req("OPTIONS", "/scan", origin: "https://evil.example"),
                    req("POST", "/scan", origin: "https://evil.example", token: token, body: #"{"scanner":"fake:flatbed"}"#)] {
        let response = await router.handle(request)
        #expect(response.status == 403)
        #expect(response.header("Access-Control-Allow-Origin") == nil)
    }
}

@Test func preflight() async {
    let (router, _) = makeRouter()
    let response = await router.handle(req("OPTIONS", "/anything", origin: "null",
                                           headers: ["Access-Control-Request-Private-Network": "true"]))
    #expect(response.status == 204)
    #expect(response.header("Access-Control-Allow-Origin") == "null")
    #expect(response.header("Access-Control-Allow-Methods") == "GET, POST, OPTIONS")
    #expect(response.header("Access-Control-Allow-Headers") == "Content-Type, Authorization")
    #expect(response.header("Access-Control-Max-Age") == "600")
    #expect(response.header("Access-Control-Allow-Private-Network") == "true")
    let plain = await router.handle(req("OPTIONS", "/scan", origin: "null"))
    #expect(plain.header("Access-Control-Allow-Private-Network") == nil)
}

@Test func healthReportsPairing() async {
    let (router, token) = makeRouter()
    let anonymous = object(await router.handle(req("GET", "/health")))
    #expect(anonymous["ok"] as? Bool == true)
    #expect(anonymous["helper"] as? String == "dossiary-scan-helper-macos")
    #expect(anonymous["version"] as? String == HelperVersion.string)
    #expect(anonymous["protocol"] as? Int == 2)
    #expect(anonymous["paired"] as? Bool == false)
    #expect(object(await router.handle(req("GET", "/health", token: token)))["paired"] as? Bool == true)
}

@Test func routingErrors() async {
    let (router, _) = makeRouter()
    #expect(await router.handle(req("GET", "/nope")).status == 404)
    #expect(await router.handle(req("PUT", "/nope")).status == 404)
    let wrong = await router.handle(req("POST", "/health"))
    #expect(wrong.status == 405)
    #expect(wrong.header("Allow") == "GET, OPTIONS")
    #expect(await router.handle(req("GET", "/scan")).header("Allow") == "POST, OPTIONS")
    #expect(await router.handle(req("HEAD", "/health")).status == 405)
    let unpaired = await router.handle(req("GET", "/scanners", origin: "null"))
    #expect(unpaired.status == 401)
    #expect(unpaired.header("Access-Control-Allow-Origin") == "null")
    #expect(await router.handle(req("GET", "/scanners", headers: ["Authorization": "Basic abc"])).status == 401)
    let errorBody = object(await router.handle(req("GET", "/nope")))
    #expect(errorBody["ok"] as? Bool == false && errorBody["partial"] as? Bool == false)
    #expect(!(errorBody["message"] as? String ?? "").isEmpty)
}

@Test func tokenComesBeforeBodyChecks() async {
    let (router, token) = makeRouter()
    let bad = HTTPRequest(method: "POST", path: "/scan", headers: [:], body: Data(),
                          bodyError: ProtocolError(400, "The request has an invalid Content-Length."))
    #expect(await router.handle(bad).status == 401)
    let badPaired = HTTPRequest(method: "POST", path: "/scan", headers: ["Authorization": "Bearer \(token)"],
                                body: Data(), bodyError: ProtocolError(400, "The request has an invalid Content-Length."))
    #expect(await router.handle(badPaired).status == 400)
}

@Test func scannersAndScan() async throws {
    let (router, token) = makeRouter()
    let list = object(await router.handle(req("GET", "/scanners", token: token)))["scanners"] as? [[String: Any]]
    #expect(list?.count == 9)
    let scan = await router.handle(req("POST", "/scan", origin: "http://localhost:8000", token: token,
                                       body: #"{"scanner":"fake:flatbed"}"#))
    #expect(scan.status == 200)
    #expect(scan.header("Access-Control-Allow-Origin") == "http://localhost:8000")
    #expect(scan.header("Vary") == "Origin")
    let files = object(scan)["files"] as? [[String: Any]]
    #expect(files?.count == 1 && files?[0]["pages"] as? Int == 1)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:empty"}"#)).status == 500)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:offline"}"#)).status == 503)
}

@Test func pairEndpoint() async {
    let (router, _) = makeRouter()
    let ok = object(await router.handle(req("POST", "/pair", body: #"{"code":"000000","client":"Test"}"#)))
    #expect(ok["ok"] as? Bool == true && (ok["token"] as? String)?.isEmpty == false)
    let refused = await router.handle(req("POST", "/pair", origin: "null", body: #"{"code":"000001"}"#))
    #expect(refused.status == 403)
    #expect(refused.header("Access-Control-Allow-Origin") == "null")
    #expect(await router.handle(req("POST", "/pair", body: "{not json")).status == 400)
}

@Test func secondScanWhileOneRunsIs409() async throws {
    let (router, token) = makeRouter()
    async let slow = router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:slow"}"#))
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:flatbed"}"#)).status == 409)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:flatbed","resolution":1}"#)).status == 422)
    #expect(await router.handle(req("GET", "/health")).status == 200)
    #expect(await slow.status == 200)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:flatbed"}"#)).status == 200)
}

@Test func hostHeaderRules() async {
    let (router, _) = makeRouter()
    for host in [nil, "127.0.0.1", "127.0.0.1:8766", "localhost", "LOCALHOST:8766", "[::1]", "[::1]:8766"] {
        let r = await router.handle(req("GET", "/health", headers: host.map { ["Host": $0] } ?? [:]))
        #expect(r.status == 200, "\(host ?? "none")")
    }
    for host in ["evil.example:8766", "evil.example", "localhost.evil.example", "127.0.0.1.evil.example"] {
        let r = await router.handle(req("OPTIONS", "/scan", headers: ["Host": host]))
        #expect(r.status == 403, "\(host)")
        #expect(r.header("Access-Control-Allow-Origin") == nil)
        #expect(object(r)["ok"] as? Bool == false)
    }
}

private func makeOcrRouter() async -> (Router, String) {
    let pairing = PairingStore(mode: .fake)
    let token = try! pairing.pair(code: "000000", client: nil)
    let queue = OcrJobQueue(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("router-ocr-\(UUID().uuidString)"), engine: FakeOcrEngine(delay: 0.3))
    await queue.start()
    return (Router(backend: FakeBackend(), pairing: pairing, ocrJobs: queue), token)
}

@Test func ocrJobLifecycle() async throws {
    let (router, token) = await makeOcrRouter()
    let scan = object(await router.handle(req("POST", "/scan", token: token,
                                              body: #"{"scanner":"fake:ocr","ocr":true,"ocrLanguages":["deu"]}"#)))
    let file = try #require((scan["files"] as? [[String: Any]])?.first)
    let job = try #require(file["ocrJob"] as? String)
    #expect(OcrJobQueue.isValidID(job))
    let pending = await router.handle(req("GET", "/ocr/\(job)", origin: "null", token: token))
    #expect(pending.status == 202)
    #expect(pending.header("Access-Control-Allow-Origin") == "null")
    #expect(object(pending)["state"] as? String != nil && object(pending)["position"] as? Int == 0)
    try await Task.sleep(nanoseconds: 600_000_000)
    let done = await router.handle(req("GET", "/ocr/\(job)", token: token))
    #expect(done.status == 200)
    let out = try #require((object(done)["files"] as? [[String: Any]])?.first)
    #expect(out["name"] as? String == file["name"] as? String)
    #expect(out["pages"] as? Int == 1)
    #expect((await router.handle(req("GET", "/ocr/\(job)", token: token))).status == 404)
}

@Test func ocrEndpointRules() async {
    let (router, token) = await makeOcrRouter()
    #expect((await router.handle(req("GET", "/ocr/no-such-job-0000000000000"))).status == 401)
    #expect((await router.handle(req("GET", "/ocr/no-such-job-0000000000000", token: token))).status == 404)
    #expect((await router.handle(req("GET", "/ocr/", token: token))).status == 404)
    #expect((await router.handle(req("GET", "/ocr", token: token))).status == 404)
    #expect((await router.handle(req("GET", "/ocr/a/b", token: token))).status == 404)
    let post = await router.handle(req("POST", "/ocr/no-such-job-0000000000000", token: token, body: "{}"))
    #expect(post.status == 405)
    #expect(post.header("Allow") == "GET, OPTIONS")
}

@Test func scanWithoutOcrHasNoJobs() async throws {
    let (router, token) = await makeOcrRouter()
    let scan = object(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:ocr"}"#)))
    let file = try #require((scan["files"] as? [[String: Any]])?.first)
    #expect(file["ocrJob"] == nil)
}

@Test func failedSubmitStillAnswersTheScan() async throws {
    let pairing = PairingStore(mode: .fake)
    let token = try pairing.pair(code: "000000", client: nil)
    // The queue's root is a regular file, so no job folder can be made.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("router-ocr-file-\(UUID().uuidString)")
    try Data("x".utf8).write(to: root)
    let queue = OcrJobQueue(root: root, engine: FakeOcrEngine())
    let router = Router(backend: FakeBackend(), pairing: pairing, ocrJobs: queue)
    let response = await router.handle(req("POST", "/scan", token: token,
                                            body: #"{"scanner":"fake:ocr","ocr":true}"#))
    #expect(response.status == 200)
    let files = try #require(object(response)["files"] as? [[String: Any]])
    #expect(files.count == 1)
    #expect(files.first?["ocrJob"] == nil)
}

@Test func realScannersGetTheEngineLanguages() async {
    let pairing = PairingStore(mode: .fake)
    let token = try! pairing.pair(code: "000000", client: nil)
    let queue = OcrJobQueue(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("router-ocr-\(UUID().uuidString)"), engine: FakeOcrEngine())
    let router = Router(backend: FakeBackend(), pairing: pairing, ocrJobs: queue, ocrLanguages: ["eng"])
    let list = object(await router.handle(req("GET", "/scanners", token: token)))["scanners"] as? [[String: Any]] ?? []
    let flatbed = list.first { $0["id"] as? String == "fake:flatbed" }
    let ocr = list.first { $0["id"] as? String == "fake:ocr" }
    let flatbedLanguages = ((flatbed?["ocr"] as? [String: Any])?["languages"] as? [String]) ?? []
    let ocrLanguages = ((ocr?["ocr"] as? [String: Any])?["languages"] as? [String]) ?? []
    #expect(flatbedLanguages == ["eng"])
    #expect(ocrLanguages == ["deu", "eng"])  // its own list wins
}

private func remoteRouter(handler: @escaping @Sendable (RemoteRequest) throws -> (Int, Any)) -> (Router, String, RemoteServer) {
    let pairing = PairingStore(mode: .fake)
    let token = try! pairing.pair(code: "000000", client: nil)
    let (store, server) = pairedStore()
    let remote = RemoteScanners(store: store, transport: { _ in FakeTransport(handler: handler) })
    return (Router(backend: FakeBackend(), pairing: pairing, remote: remote), token, server)
}

@Test func networkScannersAreListedBesideLocalOnes() async {
    let (router, token, server) = remoteRouter { _ in (200, ["scanners": [piScanner]]) }
    let ids = ((object(await router.handle(req("GET", "/scanners", token: token)))["scanners"]) as? [[String: Any]] ?? [])
        .compactMap { $0["id"] as? String }
    #expect(ids.contains("remote:\(server.id):sane:ix500"))
    #expect(ids.contains { $0.hasPrefix("fake:") })
}

@Test func scansOnANetworkScannerAreForwarded() async {
    let (router, token, server) = remoteRouter { request in
        request.path == "/scanners" ? (200, ["scanners": [piScanner]])
            : (200, ["ok": true, "partial": false, "message": "1 page scanned.",
                     "files": [["name": "scan_1.pdf", "pages": 1, "data": "JVBERg==", "ocrJob": "j1"]]])
    }
    let body = #"{"scanner":"remote:\#(server.id):sane:ix500","source":"feeder","ocr":true,"ocrLanguages":["deu"]}"#
    let response = await router.handle(req("POST", "/scan", token: token, body: body))
    #expect(response.status == 200)
    let file = (object(response)["files"] as? [[String: Any]])?.first
    #expect(file?["ocrJob"] as? String == "remote.\(server.id).j1")
}

@Test func networkOcrJobsAreForwarded() async {
    let (router, token, server) = remoteRouter { _ in (202, ["ok": true, "state": "running", "position": 0]) }
    let response = await router.handle(req("GET", "/ocr/remote.\(server.id).j1", token: token))
    #expect(response.status == 202 && object(response)["state"] as? String == "running")
}
