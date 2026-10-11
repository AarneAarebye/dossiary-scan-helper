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
    #expect(list?.count == 7)
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
