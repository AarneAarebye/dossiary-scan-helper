import Foundation

/// PROTOCOL.md "Fake scanner mode".
public final class FakeBackend: ScannerBackend, @unchecked Sendable {
    public init() {}

    public func listScanners() async -> [ScannerInfo] { FakeScanners.infos }

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {}  // the fakes never change

    public func scan(scannerID: String, settings: ScanSettings) async throws -> ScanDocuments {
        guard let fake = FakeScanners.all.first(where: { $0.info.id == scannerID }) else {
            throw ProtocolError(404, "No scanner with id “\(scannerID)”.")
        }
        if fake.offline {
            throw ProtocolError(503, "\(fake.info.name) isn't reachable. Check that it's switched on and connected.")
        }
        if fake.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(fake.delay * 1_000_000_000)) }
        if fake.empty { throw ProtocolError(500, FakeScanners.emptyFeederMessage) }
        let plan = FakeBackend.plan(fake, settings)
        let documents = try plan.documents.map { try $0.map(FakePages.render) }
        guard !fake.info.ocrLanguages.isEmpty else {
            return ScanDocuments(documents: documents, partialMessage: plan.partialMessage)
        }
        // fake:ocr writes its own PDFs so the conformance suite can search their bytes: with ocr the plain file
        // has no text (the job adds it), without ocr it carries the page text like any searchable flatbed scan.
        let pdfs = zip(plan.documents, documents).map { texts, pages in
            RawPdf.write(zip(texts, pages).map { text, page in
                RawPdf.Page(jpeg: page.data, widthPx: FakePages.width, heightPx: FakePages.height, dpi: page.dpi,
                            text: settings.ocr ? nil : text)
            })
        }
        return ScanDocuments(documents: documents, partialMessage: plan.partialMessage, pdfs: pdfs,
                             fakeTexts: settings.ocr ? plan.documents : nil)
    }

    /// Which page texts a fake scan returns, grouped into documents, and the jam message if any.
    public static func plan(_ fake: FakeScanner, _ settings: ScanSettings) -> (documents: [[String]], partialMessage: String?) {
        var pages: [String]
        if settings.source == .flatbed {
            pages = ["Flatbed page 1"]
        } else {
            let sheets = fake.jamAfter.map { Array(fake.sheets.prefix($0)) } ?? fake.sheets
            pages = []
            for sheet in sheets {
                pages.append(sheet)
                if settings.duplex { pages.append(sheet.isEmpty ? "" : "\(sheet) back") }
            }
        }

        var documents: [[String]]
        if settings.extra("splitOnBlank") {
            documents = []
            var current: [String] = []
            for page in pages {
                if page.isEmpty {
                    if !current.isEmpty { documents.append(current) }
                    current = []
                } else {
                    current.append(page)
                }
            }
            if !current.isEmpty { documents.append(current) }
        } else {
            if settings.extra("skipBlankPages") { pages = pages.filter { !$0.isEmpty } }
            documents = [pages]
        }

        if let jamAfter = fake.jamAfter, settings.source == .feeder {
            return (documents, "Paper jam after \(jamAfter) sheets. The pages before it were kept.")
        }
        return (documents, nil)
    }
}
