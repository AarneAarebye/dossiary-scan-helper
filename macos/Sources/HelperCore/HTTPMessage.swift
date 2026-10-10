import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    /// Set when Content-Length was invalid or too large; reported only by endpoints that read the body.
    public var bodyError: ProtocolError?

    public init(method: String, path: String, headers: [String: String], body: Data, bodyError: ProtocolError?) {
        self.method = method
        self.path = path
        var lowered: [String: String] = [:]
        for (name, value) in headers where lowered[name.lowercased()] == nil { lowered[name.lowercased()] = value }
        self.headers = lowered
        self.body = body
        self.bodyError = bodyError
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public func jsonBody() throws -> Any {
        if let bodyError { throw bodyError }
        return try JSONBody.parse(body)
    }
}

/// Incremental HTTP/1.1 request parser: one request per connection.
public struct HTTPRequestParser {
    public static let maxHeaderBytes = 65_536
    public static let maxBody = 1_000_000

    public enum Result { case needMore, done(HTTPRequest), malformed }

    private var buffer = Data()
    private var head: (method: String, path: String, headers: [String: String], bodyStart: Int, length: Int)?

    public init() {}

    public mutating func feed(_ data: Data) -> Result {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return buffer.count > HTTPRequestParser.maxHeaderBytes ? .malformed : .needMore
            }
            guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .isoLatin1) else { return .malformed }
            var lines = text.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
            guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") || requestLine[1] == "*" else {
                return .malformed
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { return .malformed }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if headers[name] == nil { headers[name] = value }
            }
            let target = String(requestLine[1])
            let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let method = String(requestLine[0])
            let bodyStart = end.upperBound - buffer.startIndex

            if let rawLength = headers["content-length"] {
                guard rawLength.range(of: "^[0-9]+$", options: .regularExpression) != nil, let length = Int(rawLength) else {
                    return .done(HTTPRequest(method: method, path: path, headers: headers, body: Data(),
                                             bodyError: ProtocolError(400, "The request has an invalid Content-Length.")))
                }
                guard length <= HTTPRequestParser.maxBody else {
                    return .done(HTTPRequest(method: method, path: path, headers: headers, body: Data(),
                                             bodyError: ProtocolError(400, "The request body is too large.")))
                }
                head = (method, path, headers, bodyStart, length)
            } else {
                head = (method, path, headers, bodyStart, 0)
            }
        }
        guard let head else { return .needMore }
        let available = buffer.count - head.bodyStart
        guard available >= head.length else { return .needMore }
        let start = buffer.startIndex + head.bodyStart
        let body = buffer.subdata(in: start..<(start + head.length))
        return .done(HTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body, bodyError: nil))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }

    /// A JSON response; `origin` (an allowed Origin, or nil) adds the CORS headers.
    public static func json(_ status: Int, _ payload: [String: Any], origin: String?,
                            extraHeaders: [(String, String)] = []) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        var headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
        headers += extraHeaders
        if let origin { headers += [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")] }
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    static let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                          404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 422: "Unprocessable Entity",
                          500: "Internal Server Error", 503: "Service Unavailable"]

    /// The bytes to send. `includeBody: false` for HEAD (headers still give the would-be length).
    public func serialized(includeBody: Bool) -> Data {
        var text = "HTTP/1.1 \(status) \(HTTPResponse.reasons[status] ?? "Status")\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(text.utf8)
        if includeBody { data.append(body) }
        return data
    }
}
