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

        for key in ["source", "colorMode", "format", "area"] where object[key] != nil && !(object[key] is String) {
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

        if object["ocr"] != nil && JSONBody.bool(object["ocr"]) == nil {
            throw ProtocolError(400, "“ocr” must be true or false.")
        }
        var ocrLanguages: [String] = []
        if let raw = object["ocrLanguages"] {
            guard let list = raw as? [Any], list.allSatisfy({ $0 is String }) else {
                throw ProtocolError(400, "“ocrLanguages” must be a list of language codes.")
            }
            for case let code as String in list where !ocrLanguages.contains(code) { ocrLanguages.append(code) }
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
        guard scanner.formats.contains(format) else {
            throw ProtocolError(422, "\(scanner.name) can't make \(format) files; it offers \(scanner.formats.joined(separator: ", ")).")
        }
        if object["area"] != nil && scanner.areas.isEmpty {
            throw ProtocolError(422, "\(scanner.name) has no scan areas.")
        }
        let area = object["area"] as? String ?? scanner.areas.first
        if let area, !scanner.areas.contains(area) {
            throw ProtocolError(422, "\(scanner.name) doesn't offer the area “\(area)”.")
        }
        if format == "jpeg" && colorMode == .bw {
            throw ProtocolError(422, "JPEG can't be black and white; use PNG or PDF.")
        }
        if format != "pdf" && source == .feeder {
            throw ProtocolError(422, "Images can only be scanned from the flatbed.")
        }
        let duplex = JSONBody.bool(object["duplex"]) ?? false
        if duplex && !(scanner.duplex && source == .feeder) {
            throw ProtocolError(422, "\(scanner.name) can't scan both sides from the \(source.rawValue).")
        }
        for (name, on) in extras.sorted(by: { $0.key < $1.key }) where on && !scanner.extras.contains(name) {
            throw ProtocolError(422, "\(scanner.name) doesn't offer “\(name)”.")
        }
        let ocr = JSONBody.bool(object["ocr"]) ?? false
        if ocr && format != "pdf" {
            throw ProtocolError(422, "A searchable PDF can't be made from an image; scan to PDF instead.")
        }
        if ocr {
            guard !scanner.ocrLanguages.isEmpty else {
                throw ProtocolError(422, "\(scanner.name) can't make searchable PDFs.")
            }
            for code in ocrLanguages where !scanner.ocrLanguages.contains(code) {
                throw ProtocolError(422, "\(scanner.name) can't recognize text in “\(code)”.")
            }
        }

        if let area {
            let size: SizeMM? = area == Areas.full
                ? scanner.fullAreaMM
                : Areas.named(area).map { SizeMM(width: $0.widthMM, height: $0.heightMM) }
            if let size {
                let pixels = Areas.pixelCount(widthMM: size.width, heightMM: size.height, dpi: resolution)
                if Areas.isOverLimit(pixels) {
                    let label = area == Areas.full ? "The whole glass" : (Areas.named(area)?.label ?? area)
                    let megapixels = Int((Double(pixels) / 1_000_000).rounded())
                    throw ProtocolError(422, "\(label) at \(resolution) dpi is too large (\(megapixels) megapixels; "
                        + "the limit is \(Areas.maxPixels / 1_000_000)): choose a smaller area or a lower resolution.")
                }
            }
        }

        return (scanner, ScanSettings(source: source, duplex: duplex, colorMode: colorMode,
                                      resolution: resolution, extras: extras,
                                      ocr: ocr, ocrLanguages: ocr ? ocrLanguages : [],
                                      format: format, area: area))
    }
}
