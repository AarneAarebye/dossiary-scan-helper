import Foundation

/// The 200 answer to POST /scan.
public enum ScanResponse {
    public static func pagesMessage(_ count: Int) -> String {
        count == 1 ? "1 page scanned." : "\(count) pages scanned."
    }

    public static func payload(_ result: ScanDocuments, date: Date) throws -> [String: Any] {
        let documents = result.documents.filter { !$0.isEmpty }
        guard !documents.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: date)
        var files: [[String: Any]] = []
        for (index, pages) in documents.enumerated() {
            let name = documents.count == 1 ? "scan_\(stamp).pdf" : "scan_\(stamp)_\(index + 1).pdf"
            files.append(["name": name, "pages": pages.count,
                          "data": try PdfBuilder.makePdf(pages).base64EncodedString()])
        }
        let total = documents.reduce(0) { $0 + $1.count }
        let partial = result.partialMessage != nil
        return ["ok": !partial, "partial": partial,
                "message": result.partialMessage ?? pagesMessage(total), "files": files]
    }
}
