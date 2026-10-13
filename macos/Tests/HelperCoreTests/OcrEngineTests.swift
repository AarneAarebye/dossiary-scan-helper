import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import HelperCore

/// An A4 page at 150 dpi with the given lines of black 40 px Helvetica text.
private func textPage(_ lines: [String]) throws -> PageImage {
    let width = 1240, height = 1754
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
    for (index, text) in lines.enumerated() {
        let attributed = NSAttributedString(string: text,
                                            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 100, y: height - 200 - index * 80)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    return PageImage(data: try ImageEncoding.jpeg(context.makeImage()!, quality: 0.9), dpi: 150)
}

private func pixels(_ pdf: Data) -> [UInt8] {
    let document = PDFDocument(data: pdf)!
    let page = document.page(at: 0)!
    let box = page.bounds(for: .mediaBox)
    let width = Int(box.width), height = Int(box.height)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    page.draw(with: .mediaBox, to: context)
    return withExtendedLifetime(document) { Array(UnsafeBufferPointer(start: context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4),
                                     count: width * height * 4)) }
}

@Test func offeredCodesAreProtocolCodes() {
    let codes = VisionOcrEngine.offeredCodes()
    #expect(codes.contains("deu") && codes.contains("eng"))
    #expect(codes.allSatisfy { OcrLanguages.visionLanguage(for: $0) != nil })
}

@Test func visionMakesTheTextSearchableAndInvisible() async throws {
    let page = try textPage(["Rechnung Nummer 4711", "Gesamtbetrag 123,45 EUR"])
    let input = OcrJobInput(pages: [page, try textPage([])], languages: ["deu", "eng"], fakeTexts: nil, createdAt: Date())
    let pdf = try await VisionOcrEngine().makeSearchable(input)
    let document = try #require(PDFDocument(data: pdf))
    #expect(document.pageCount == 2)
    let text = document.page(at: 0)?.string ?? ""
    #expect(text.contains("Rechnung Nummer 4711"))
    #expect(text.contains("Gesamtbetrag"))
    // The blank page simply has no text; the job still succeeds.
    let blankText: String = document.page(at: 1)?.string ?? ""
    #expect(blankText.isEmpty)
    // Invisible: the page looks exactly like the plain scan.
    #expect(pixels(pdf) == pixels(try PdfBuilder.makePdf([page, try textPage([])])))
    // The text sits where it is on the page (upper part, left side).
    let found = try #require(document.findString("Gesamtbetrag", withOptions: []).first)
    let bounds = found.bounds(for: document.page(at: 0)!)
    #expect(bounds.minY > 600)
    // Drawn at x = 100 px at 150 dpi = 48 pt; the line's right edge follows from its real width.
    #expect(abs(bounds.minX - 48) <= 2)
    let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: "Gesamtbetrag 123,45 EUR", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    let rightEdge = 48 + CTLineGetTypographicBounds(line, nil, nil, nil) * 72 / 150
    let eur = try #require(document.findString("EUR", withOptions: []).first)
    #expect(abs(eur.bounds(for: document.page(at: 0)!).maxX - rightEdge) <= 20)
}

@Test func unreadablePageFailsTheJob() async {
    let input = OcrJobInput(pages: [PageImage(data: Data("not an image".utf8), dpi: 300)], languages: [],
                            fakeTexts: nil, createdAt: Date())
    await #expect(throws: ProtocolError.self) { try await VisionOcrEngine().makeSearchable(input) }
}

@Test func rawPdfIsByteSearchableAndOpens() throws {
    let page = try FakePages.render("Flatbed page 1")
    let plain = RawPdf.write([RawPdf.Page(jpeg: page.data, widthPx: 413, heightPx: 585, dpi: 50, text: nil)])
    let searchable = RawPdf.write([RawPdf.Page(jpeg: page.data, widthPx: 413, heightPx: 585, dpi: 50,
                                               text: "Flatbed page 1")])
    #expect(plain.starts(with: Data("%PDF-".utf8)))
    #expect(plain.range(of: Data("Flatbed page 1".utf8)) == nil)
    #expect(searchable.range(of: Data("Flatbed page 1".utf8)) != nil)
    let document = try #require(PDFDocument(data: searchable))
    #expect(document.pageCount == 1)
    #expect(document.string?.contains("Flatbed page 1") == true)
    #expect(pixels(searchable) == pixels(plain))
}

@Test func fakeEngineWaitsTwoSecondsAfterTheScan() async throws {
    let page = try FakePages.render("Flatbed page 1")
    let created = Date()
    let input = OcrJobInput(pages: [page], languages: [], fakeTexts: ["Flatbed page 1"], createdAt: created)
    let pdf = try await FakeOcrEngine().makeSearchable(input)
    #expect(Date().timeIntervalSince(created) >= 1.9)
    #expect(pdf.range(of: Data("Flatbed page 1".utf8)) != nil)
}

private struct RecognitionFailed: Error {}

@Test func recognitionFailingOnEveryPageFailsTheJob() async throws {
    let engine = VisionOcrEngine(recognizer: { _, _ in throw RecognitionFailed() })
    let input = OcrJobInput(pages: [try textPage(["A"]), try textPage(["B"])], languages: [], fakeTexts: nil,
                            createdAt: Date())
    await #expect(throws: ProtocolError(500, "Text recognition failed on every page.")) {
        try await engine.makeSearchable(input)
    }
}

@Test func recognitionFailingOnOnePageStillSucceeds() async throws {
    let calls = Counter()
    let engine = VisionOcrEngine(recognizer: { _, _ in
        if calls.next() == 0 { throw RecognitionFailed() }
        return [OcrLine(text: "Zweite Seite", box: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.03))]
    })
    let input = OcrJobInput(pages: [try textPage(["A"]), try textPage(["B"])], languages: [], fakeTexts: nil,
                            createdAt: Date())
    let document = try #require(PDFDocument(data: try await engine.makeSearchable(input)))
    #expect(document.pageCount == 2)
    let secondText: String = document.page(at: 1)?.string ?? ""
    #expect(secondText.contains("Zweite Seite"))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { value += 1; lock.unlock() }; return value }
}
