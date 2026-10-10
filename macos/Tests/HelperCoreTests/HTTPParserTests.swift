import Foundation
import Testing
@testable import HelperCore

private func parse(_ text: String, chunks: Int = 1) -> HTTPRequestParser.Result {
    var parser = HTTPRequestParser()
    let data = Data(text.utf8)
    let size = max(1, data.count / chunks)
    var result = HTTPRequestParser.Result.needMore
    var offset = 0
    while offset < data.count {
        result = parser.feed(data.subdata(in: offset..<min(offset + size, data.count)))
        offset += size
        if case .done = result { break }
    }
    return result
}

private func request(_ text: String, chunks: Int = 1) throws -> HTTPRequest {
    guard case .done(let request) = parse(text, chunks: chunks) else { throw ProtocolError(0, "not done") }
    return request
}

@Test func parsesAGetWithQueryAndHeaders() throws {
    let r = try request("GET /health?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: null\r\nX-Two: a\r\nx-two: b\r\n\r\n")
    #expect(r.method == "GET")
    #expect(r.path == "/health")
    #expect(r.header("ORIGIN") == "null")
    #expect(r.header("x-two") == "a")
    #expect(r.body.isEmpty && r.bodyError == nil)
}

@Test func readsABodyArrivingInPieces() throws {
    let body = #"{"scanner":"fake:flatbed"}"#
    let r = try request("POST /scan HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", chunks: 7)
    #expect(String(decoding: r.body, as: UTF8.self) == body)
}

@Test func waitsForTheWholeBody() {
    if case .needMore = parse("POST /scan HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345") {} else { Issue.record("expected needMore") }
}

@Test func badContentLengthIsABodyErrorNotMalformed() throws {
    for value in ["abc", "-1", "1.5", "", "1000001"] {
        let r = try request("POST /scan HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n")
        #expect(r.bodyError?.status == 400, "\(value)")
    }
}

@Test func garbageIsMalformed() {
    if case .malformed = parse("NONSENSE\r\n\r\n") {} else { Issue.record("expected malformed") }
    if case .malformed = parse("GET / HTTP/1.1\r\nNoColonHere\r\n\r\n") {} else { Issue.record("expected malformed") }
    if case .malformed = parse("GET / HTTP/1.1\r\n" + String(repeating: "a", count: 70_000)) {} else {
        Issue.record("expected malformed for oversized headers")
    }
}

@Test func responseSerialization() {
    let response = HTTPResponse.json(405, ["ok": false], origin: "null", extraHeaders: [("Allow", "GET, OPTIONS")])
    let text = String(decoding: response.serialized(includeBody: true), as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
    #expect(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
    #expect(text.contains("Access-Control-Allow-Origin: null\r\n"))
    #expect(text.contains("Vary: Origin\r\n"))
    #expect(text.contains("Allow: GET, OPTIONS\r\n"))
    #expect(text.contains("Connection: close\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{\"ok\":false}"))
    let head = String(decoding: response.serialized(includeBody: false), as: UTF8.self)
    #expect(head.hasSuffix("\r\n\r\n") && head.contains("Content-Length: 12\r\n"))
}
