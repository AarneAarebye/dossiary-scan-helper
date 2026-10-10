import Foundation

public enum JSONBody {
    /// Parses a request body. An empty body is JSON `null` (the protocol: no Content-Length = empty body).
    public static func parse(_ data: Data) throws -> Any {
        if data.isEmpty { return NSNull() }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ProtocolError(400, "The request body isn't valid JSON.")
        }
    }

    /// An integer is a JSON number without fraction or exponent: JSONSerialization makes those
    /// non-float NSNumbers, while `300.0` and `3e2` come back as floats. Booleans are NSNumbers too.
    public static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.intValue
    }

    /// `as? Bool` would accept the number 1; only JSON true/false count.
    public static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
