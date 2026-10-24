import Foundation

/// One scanned page: encoded image bytes (JPEG, PNG or TIFF) and the resolution they were scanned at.
public struct PageImage: Sendable {
    public let data: Data
    public let dpi: Int
    public init(data: Data, dpi: Int) { self.data = data; self.dpi = dpi }
}

/// A finished image scan: the file's bytes as scanned, `format` being "jpeg" or "png".
public struct ImageFile: Sendable {
    public let data: Data
    public let format: String
    public init(data: Data, format: String) { self.data = data; self.format = format }
}

/// A scan's result: one page list per PDF. A non-nil `partialMessage` means `ok: false, partial: true`.
public struct ScanDocuments: Sendable {
    public var documents: [[PageImage]]
    public var partialMessage: String?
    /// Already-built PDFs, one per document (fake:ocr only, so its text stays byte-searchable).
    public var pdfs: [Data]?
    /// fake:ocr with `ocr: true` only: each document's page texts, for FakeOcrEngine.
    public var fakeTexts: [[String]]?
    /// An image scan (one JPEG or PNG file instead of pages for a PDF).
    public var image: ImageFile?
    public init(documents: [[PageImage]], partialMessage: String?, pdfs: [Data]? = nil, fakeTexts: [[String]]? = nil,
                image: ImageFile? = nil) {
        self.documents = documents; self.partialMessage = partialMessage; self.pdfs = pdfs; self.fakeTexts = fakeTexts
        self.image = image
    }
}

/// Where scanners come from: the fakes, or ImageCaptureCore.
public protocol ScannerBackend: AnyObject, Sendable {
    func listScanners() async -> [ScannerInfo]
    /// Throws ProtocolError (503 unreachable/denied, 500 failed with no page).
    func scan(scannerID: String, settings: ScanSettings) async throws -> ScanDocuments
    /// Called (on any thread) whenever the scanner list changes.
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void)
    /// Before quitting: cancels any running scan and closes the scanner sessions this helper has open, so the
    /// scanner isn't left busy for every other app.
    func stopScans() async
}

public extension ScannerBackend {
    func stopScans() async {}
}
