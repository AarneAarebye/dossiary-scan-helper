import Foundation

public enum Source: String, Sendable { case flatbed, feeder }
public enum ColorMode: String, Sendable { case color, gray, bw }

/// One entry of GET /scanners.
public struct ScannerInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var sources: [Source]
    public var duplex: Bool
    public var colorModes: [ColorMode]
    public var resolutions: [Int]
    public var extras: [String]
    /// OCR codes this scanner's helper can recognize; empty means no OCR.
    public var ocrLanguages: [String]

    public init(id: String, name: String, sources: [Source], duplex: Bool, colorModes: [ColorMode],
                resolutions: [Int], extras: [String], ocrLanguages: [String] = []) {
        self.id = id; self.name = name; self.sources = sources; self.duplex = duplex
        self.colorModes = colorModes; self.resolutions = resolutions; self.extras = extras
        self.ocrLanguages = ocrLanguages
    }

    public var json: [String: Any] {
        var object: [String: Any] = ["id": id, "name": name, "sources": sources.map(\.rawValue), "duplex": duplex,
                                     "colorModes": colorModes.map(\.rawValue), "resolutions": resolutions,
                                     "extras": extras]
        if !ocrLanguages.isEmpty { object["ocr"] = ["languages": ocrLanguages] }
        return object
    }

    /// A scanner as another helper (scanix500-server) lists it in GET /scanners.
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        let ocr = json["ocr"] as? [String: Any]
        self.init(id: id, name: name,
                  sources: (json["sources"] as? [String] ?? []).compactMap(Source.init(rawValue:)),
                  duplex: json["duplex"] as? Bool ?? false,
                  colorModes: (json["colorModes"] as? [String] ?? []).compactMap(ColorMode.init(rawValue:)),
                  resolutions: json["resolutions"] as? [Int] ?? [],
                  extras: json["extras"] as? [String] ?? [],
                  ocrLanguages: ocr?["languages"] as? [String] ?? [])
    }
}

/// A validated POST /scan request, with every default filled in.
public struct ScanSettings: Equatable, Sendable {
    public var source: Source
    public var duplex: Bool
    public var colorMode: ColorMode
    public var resolution: Int
    public var extras: [String: Bool]
    public var ocr: Bool
    /// Deduplicated, in request order.
    public var ocrLanguages: [String]

    public init(source: Source, duplex: Bool, colorMode: ColorMode, resolution: Int, extras: [String: Bool],
                ocr: Bool = false, ocrLanguages: [String] = []) {
        self.source = source; self.duplex = duplex; self.colorMode = colorMode
        self.resolution = resolution; self.extras = extras
        self.ocr = ocr; self.ocrLanguages = ocrLanguages
    }

    public func extra(_ name: String) -> Bool { extras[name] ?? false }
}

/// A protocol error: the HTTP status plus a message for a person.
public struct ProtocolError: LocalizedError, Equatable, Sendable {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}
