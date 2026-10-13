import Foundation

/// The 200 answer to POST /scan.
public enum ScanResponse {
    public struct File {
        public let name: String
        public let pages: [PageImage]
        public let pdf: Data
        public let fakeTexts: [String]?
    }

    public static func pagesMessage(_ count: Int) -> String {
        count == 1 ? "1 page scanned." : "\(count) pages scanned."
    }

    public static func files(_ result: ScanDocuments, date: Date) throws -> [File] {
        let kept = result.documents.indices.filter { !result.documents[$0].isEmpty }
        guard !kept.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: date)
        return try kept.enumerated().map { position, index in
            let pages = result.documents[index]
            let name = kept.count == 1 ? "scan_\(stamp).pdf" : "scan_\(stamp)_\(position + 1).pdf"
            let pdf = try result.pdfs?[safe: index] ?? PdfBuilder.makePdf(pages)
            return File(name: name, pages: pages, pdf: pdf, fakeTexts: result.fakeTexts?[safe: index])
        }
    }

    /// `ocrJobs[i]` is file i's job id, or nil when it has none.
    public static func payload(_ result: ScanDocuments, files: [File], ocrJobs: [String?] = []) -> [String: Any] {
        let entries: [[String: Any]] = files.enumerated().map { index, file in
            var entry: [String: Any] = ["name": file.name, "pages": file.pages.count,
                                        "data": file.pdf.base64EncodedString()]
            if let job = ocrJobs[safe: index] ?? nil { entry["ocrJob"] = job }
            return entry
        }
        let total = files.reduce(0) { $0 + $1.pages.count }
        let partial = result.partialMessage != nil
        return ["ok": !partial, "partial": partial,
                "message": result.partialMessage ?? pagesMessage(total), "files": entries]
    }

    public static func payload(_ result: ScanDocuments, date: Date) throws -> [String: Any] {
        payload(result, files: try files(result, date: date))
    }
}
