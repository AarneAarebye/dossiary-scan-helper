import Foundation

/// A finished real scan -> the response's documents, or the error to answer with.
public enum ScanOutcome {
    public static func documents(pages: [PageImage], errorMessage: String?, source: Source) throws -> ScanDocuments {
        if pages.isEmpty {
            if let errorMessage { throw ProtocolError(500, "The scan failed: \(errorMessage)") }
            throw ProtocolError(500, source == .feeder ? FakeScanners.emptyFeederMessage : "The scanner returned no pages.")
        }
        guard let errorMessage else { return ScanDocuments(documents: [pages], partialMessage: nil) }
        let count = pages.count == 1 ? "1 page" : "\(pages.count) pages"
        return ScanDocuments(documents: [pages],
                             partialMessage: "The scan stopped after \(count): \(errorMessage). The pages before it were kept.")
    }
}
