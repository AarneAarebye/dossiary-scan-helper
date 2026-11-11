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

    public init(id: String = UUID().uuidString, name: String, scannerID: String, scannerName: String, destination: String,
                source: Source, duplex: Bool = false, colorMode: ColorMode, resolution: Int, format: String = "pdf",
                area: String? = nil, ocr: Bool = false, ocrLanguages: [String] = []) {
        self.id = id; self.name = name; self.scannerID = scannerID; self.scannerName = scannerName
        self.destination = destination; self.source = source; self.duplex = duplex; self.colorMode = colorMode
        self.resolution = resolution; self.format = format; self.area = area; self.ocr = ocr
        self.ocrLanguages = ocrLanguages
    }
}
