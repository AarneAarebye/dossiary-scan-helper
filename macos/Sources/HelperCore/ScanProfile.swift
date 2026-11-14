import Foundation

/// A saved way of scanning: which scanner, how, and where the file goes.
public struct ScanProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var scannerID: String
    /// Remembered so the menu can name the scanner even while it is off or unreachable.
    public var scannerName: String
    /// A folder path.
    public var destination: String
    public var source: Source
    public var duplex: Bool
    public var colorMode: ColorMode
    public var resolution: Int
    /// "pdf", "jpeg" or "png".
    public var format: String
    /// An area id (see `Areas`); nil for a scanner without areas.
    public var area: String?
    public var ocr: Bool
    public var ocrLanguages: [String]
    /// Also hand the saved files to Dossiary for Mac.
    public var sendToDossiary: Bool

    public init(id: String = UUID().uuidString, name: String, scannerID: String, scannerName: String, destination: String,
                source: Source, duplex: Bool = false, colorMode: ColorMode, resolution: Int, format: String = "pdf",
                area: String? = nil, ocr: Bool = false, ocrLanguages: [String] = [], sendToDossiary: Bool = false) {
        self.id = id; self.name = name; self.scannerID = scannerID; self.scannerName = scannerName
        self.destination = destination; self.source = source; self.duplex = duplex; self.colorMode = colorMode
        self.resolution = resolution; self.format = format; self.area = area; self.ocr = ocr
        self.ocrLanguages = ocrLanguages; self.sendToDossiary = sendToDossiary
    }

    enum CodingKeys: String, CodingKey {
        case id, name, scannerID, scannerName, destination, source, duplex, colorMode, resolution, format, area, ocr, ocrLanguages, sendToDossiary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        scannerID = try c.decode(String.self, forKey: .scannerID)
        scannerName = try c.decode(String.self, forKey: .scannerName)
        destination = try c.decode(String.self, forKey: .destination)
        source = try c.decode(Source.self, forKey: .source)
        duplex = try c.decode(Bool.self, forKey: .duplex)
        colorMode = try c.decode(ColorMode.self, forKey: .colorMode)
        resolution = try c.decode(Int.self, forKey: .resolution)
        format = try c.decode(String.self, forKey: .format)
        area = try c.decodeIfPresent(String.self, forKey: .area)
        ocr = try c.decode(Bool.self, forKey: .ocr)
        ocrLanguages = try c.decode([String].self, forKey: .ocrLanguages)
        sendToDossiary = try c.decodeIfPresent(Bool.self, forKey: .sendToDossiary) ?? false
    }
}
