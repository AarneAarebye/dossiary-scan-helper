import Foundation

/// POST /scan validation, steps 1-5 of PROTOCOL.md "Request validation", in that order.
public enum ScanRequestValidator {
    public static func validate(_ body: Any, scanners: [ScannerInfo]) throws -> (ScannerInfo, ScanSettings) {
        guard let object = body as? [String: Any] else {
            throw ProtocolError(400, "The request body must be a JSON object.")
        }
        guard let scannerID = object["scanner"] as? String else {
            throw ProtocolError(400, "The request needs a scanner id.")
        }
        guard let scanner = scanners.first(where: { $0.id == scannerID }) else {
            throw ProtocolError(404, "No scanner with id “\(scannerID)”.")
        }

        for key in ["source", "colorMode", "format"] where object[key] != nil && !(object[key] is String) {
            throw ProtocolError(400, "“\(key)” must be a string.")
        }
        if object["resolution"] != nil && JSONBody.integer(object["resolution"]) == nil {
            throw ProtocolError(400, "“resolution” must be a whole number.")
        }
        if object["duplex"] != nil && JSONBody.bool(object["duplex"]) == nil {
            throw ProtocolError(400, "“duplex” must be true or false.")
        }
        var extras: [String: Bool] = [:]
        if let rawExtras = object["extras"] {
            guard let dict = rawExtras as? [String: Any] else {
                throw ProtocolError(400, "“extras” must map names to true or false.")
            }
            for (name, value) in dict {
                guard let on = JSONBody.bool(value) else {
                    throw ProtocolError(400, "“extras” must map names to true or false.")
                }
                extras[name] = on
            }
        }

        let sourceText = object["source"] as? String ?? scanner.sources[0].rawValue
        guard let source = Source(rawValue: sourceText), scanner.sources.contains(source) else {
            throw ProtocolError(422, "\(scanner.name) has no \(sourceText) source.")
        }
        let colorText = object["colorMode"] as? String ?? scanner.colorModes[0].rawValue
        guard let colorMode = ColorMode(rawValue: colorText), scanner.colorModes.contains(colorMode) else {
            throw ProtocolError(422, "\(scanner.name) can't scan in \(colorText).")
        }
        let resolution = JSONBody.integer(object["resolution"]) ?? scanner.resolutions[0]
        guard scanner.resolutions.contains(resolution) else {
            throw ProtocolError(422, "\(scanner.name) can't scan at \(resolution) dpi.")
        }
        let format = object["format"] as? String ?? "pdf"
        guard format == "pdf" else {
            throw ProtocolError(422, "Format “\(format)” isn't supported; use pdf.")
        }
        let duplex = JSONBody.bool(object["duplex"]) ?? false
        if duplex && !(scanner.duplex && source == .feeder) {
            throw ProtocolError(422, "\(scanner.name) can't scan both sides from the \(source.rawValue).")
        }
        for (name, on) in extras.sorted(by: { $0.key < $1.key }) where on && !scanner.extras.contains(name) {
            throw ProtocolError(422, "\(scanner.name) doesn't offer “\(name)”.")
        }

        return (scanner, ScanSettings(source: source, duplex: duplex, colorMode: colorMode,
                                      resolution: resolution, extras: extras))
    }
}
