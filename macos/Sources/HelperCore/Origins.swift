import Foundation

/// PROTOCOL.md "Origins (CORS)": no Origin, "null", or plain-http localhost / 127.0.0.1 on port 1-65535.
public enum Origins {
    public static func allowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        if origin == "null" { return true }
        guard let match = origin.range(of: #"^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?$"#, options: .regularExpression),
              match == origin.startIndex..<origin.endIndex else { return false }
        guard let colon = origin.dropFirst("http://".count).firstIndex(of: ":") else { return true }
        guard let port = Int(origin[origin.index(after: colon)...]) else { return false }
        return (1...65535).contains(port)
    }
}
