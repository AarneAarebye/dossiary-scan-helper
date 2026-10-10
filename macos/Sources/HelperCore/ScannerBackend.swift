import Foundation

/// One scanned page: encoded image bytes (JPEG, PNG or TIFF) and the resolution they were scanned at.
public struct PageImage: Sendable {
    public let data: Data
    public let dpi: Int
    public init(data: Data, dpi: Int) { self.data = data; self.dpi = dpi }
}

/// A scan's result: one page list per PDF. A non-nil `partialMessage` means `ok: false, partial: true`.
public struct ScanDocuments: Sendable {
    public var documents: [[PageImage]]
    public var partialMessage: String?
    public init(documents: [[PageImage]], partialMessage: String?) {
        self.documents = documents; self.partialMessage = partialMessage
    }
}

/// Where scanners come from: the fakes, or ImageCaptureCore.
public protocol ScannerBackend: AnyObject, Sendable {
    func listScanners() async -> [ScannerInfo]
    /// Throws ProtocolError (503 unreachable/denied, 500 failed with no page).
    func scan(scannerID: String, settings: ScanSettings) async throws -> ScanDocuments
    /// Called (on any thread) whenever the scanner list changes.
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void)
}
