import Foundation

/// The 200 answer to POST /scan.
public enum ScanResponse {
    public struct File {
        public let name: String
        public let pages: [PageImage]
        /// The file's bytes: a PDF, or a JPEG/PNG for an image scan.
        public let pdf: Data
        public let fakeTexts: [String]?
        public let pageCount: Int
    }

    public static func pagesMessage(_ count: Int) -> String {
        count == 1 ? "1 page scanned." : "\(count) pages scanned."
    }

    public static func imagesMessage(_ count: Int) -> String {
        count == 1 ? "1 image scanned." : "\(count) images scanned."
    }

    public static func files(_ result: ScanDocuments, date: Date) throws -> [File] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: date)
        if let image = result.image {
            let name = "scan_\(stamp).\(image.format == "png" ? "png" : "jpg")"
            return [File(name: name, pages: [], pdf: image.data, fakeTexts: nil, pageCount: 1)]
        }
        let kept = result.documents.indices.filter { !result.documents[$0].isEmpty }
        guard !kept.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        return try kept.enumerated().map { position, index in
            let pages = result.documents[index]
            let name = kept.count == 1 ? "scan_\(stamp).pdf" : "scan_\(stamp)_\(position + 1).pdf"
            let pdf = try result.pdfs?[safe: index] ?? PdfBuilder.makePdf(pages)
            return File(name: name, pages: pages, pdf: pdf, fakeTexts: result.fakeTexts?[safe: index],
                        pageCount: pages.count)
        }
    }

    /// `ocrJobs[i]` is file i's job id, or nil when it has none.
    public static func payload(_ result: ScanDocuments, files: [File], ocrJobs: [String?] = []) -> [String: Any] {
        let entries: [[String: Any]] = files.enumerated().map { index, file in
            var entry: [String: Any] = ["name": file.name, "pages": file.pageCount,
                                        "data": file.pdf.base64EncodedString()]
            if let job = ocrJobs[safe: index] ?? nil { entry["ocrJob"] = job }
            return entry
        }
        let total = files.reduce(0) { $0 + $1.pageCount }
        let partial = result.partialMessage != nil
        let message = result.image != nil ? imagesMessage(files.count) : pagesMessage(total)
        return ["ok": !partial, "partial": partial,
                "message": result.partialMessage ?? message, "files": entries]
    }

    public static func payload(_ result: ScanDocuments, date: Date) throws -> [String: Any] {
        payload(result, files: try files(result, date: date))
    }
}
