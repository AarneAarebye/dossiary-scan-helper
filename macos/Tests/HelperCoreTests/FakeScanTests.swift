import Foundation
import PDFKit
import Testing
@testable import HelperCore

private func fake(_ id: String) -> FakeScanner { FakeScanners.all.first { $0.info.id == id }! }
private func settings(_ source: Source, duplex: Bool = false, extras: [String: Bool] = [:]) -> ScanSettings {
    ScanSettings(source: source, duplex: duplex, colorMode: .color, resolution: 150, extras: extras)
}

@Test func flatbedSourceGivesOnePage() {
    #expect(FakeBackend.plan(fake("fake:feeder"), settings(.flatbed)).documents == [["Flatbed page 1"]])
}

@Test func feederDuplexGivesFrontsAndBacks() {
    #expect(FakeBackend.plan(fake("fake:feeder"), settings(.feeder, duplex: true)).documents ==
            [["Sheet 1", "Sheet 1 back", "Sheet 2", "Sheet 2 back", "Sheet 3", "Sheet 3 back"]])
}

@Test func splitterExtras() {
    let splitter = fake("fake:splitter")
    #expect(FakeBackend.plan(splitter, settings(.feeder)).documents.map(\.count) == [4])
    #expect(FakeBackend.plan(splitter, settings(.feeder, extras: ["skipBlankPages": true])).documents.map(\.count) == [3])
    #expect(FakeBackend.plan(splitter, settings(.feeder, extras: ["splitOnBlank": true])).documents ==
            [["Doc A page 1", "Doc A page 2"], ["Doc B page 1"]])
    #expect(FakeBackend.plan(splitter, settings(.feeder, extras: ["splitOnBlank": true, "skipBlankPages": true]))
            .documents.map(\.count) == [2, 1])
}

@Test func jamIsPartial() {
    let plan = FakeBackend.plan(fake("fake:jam"), settings(.feeder))
    #expect(plan.documents == [["Sheet 1", "Sheet 2"]])
    #expect(plan.partialMessage?.contains("jam") == true)
}

@Test func renderedPageIsAJpeg() throws {
    let page = try FakePages.render("Sheet 1")
    #expect(page.dpi == FakePages.dpi)
    #expect(page.data.prefix(2) == Data([0xFF, 0xD8]))
}

@Test func pdfHasOnePagePerImageAtA4Size() throws {
    let pages = try ["One", "", "Three"].map(FakePages.render)
    let pdf = try PdfBuilder.makePdf(pages)
    #expect(pdf.starts(with: Data("%PDF-".utf8)))
    let document = try #require(PDFDocument(data: pdf))
    #expect(document.pageCount == 3)
    let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(bounds.width - 595) < 3 && abs(bounds.height - 842) < 3)
    let text = String(decoding: pdf, as: UTF8.self)
    let pageObjects = try NSRegularExpression(pattern: "/Type\\s*/Page(?!s)")
        .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    #expect(pageObjects == 3)
}

@Test func emptyPdfIsRefused() {
    #expect(throws: ProtocolError.self) { try PdfBuilder.makePdf([]) }
}

@Test func responsePayloadForOneAndTwoDocuments() throws {
    let page = try FakePages.render("x")
    let date = Date(timeIntervalSince1970: 0)
    let one = try ScanResponse.payload(ScanDocuments(documents: [[page, page, page]], partialMessage: nil), date: date)
    #expect(one["ok"] as? Bool == true)
    #expect(one["partial"] as? Bool == false)
    #expect(one["message"] as? String == "3 pages scanned.")
    let files = try #require(one["files"] as? [[String: Any]])
    #expect(files.count == 1)
    let name = try #require(files[0]["name"] as? String)
    #expect(name.range(of: #"^scan_\d{8}_\d{6}\.pdf$"#, options: .regularExpression) != nil)
    #expect(files[0]["pages"] as? Int == 3)
    let encoded = try #require(files[0]["data"] as? String)
    let data = try #require(Data(base64Encoded: encoded))
    #expect(data.starts(with: Data("%PDF-".utf8)))

    let two = try ScanResponse.payload(ScanDocuments(documents: [[page], [page]], partialMessage: "Paper jam."), date: date)
    #expect(two["ok"] as? Bool == false)
    #expect(two["partial"] as? Bool == true)
    #expect(two["message"] as? String == "Paper jam.")
    let names = try #require(two["files"] as? [[String: Any]]).compactMap { $0["name"] as? String }
    #expect(names.count == 2 && names[0].hasSuffix("_1.pdf") && names[1].hasSuffix("_2.pdf"))
    #expect(ScanResponse.pagesMessage(1) == "1 page scanned.")
}

@Test func fakeBackendErrors() async {
    let backend = FakeBackend()
    do { _ = try await backend.scan(scannerID: "fake:offline", settings: settings(.flatbed)); Issue.record("no error") }
    catch let error as ProtocolError { #expect(error.status == 503) } catch { Issue.record("\(error)") }
    do { _ = try await backend.scan(scannerID: "fake:empty", settings: settings(.feeder)); Issue.record("no error") }
    catch let error as ProtocolError { #expect(error == ProtocolError(500, "No paper in the feeder.")) }
    catch { Issue.record("\(error)") }
}

@Test func fakeBackendScansTheSplitter() async throws {
    let result = try await FakeBackend().scan(scannerID: "fake:splitter",
                                              settings: settings(.feeder, extras: ["splitOnBlank": true]))
    #expect(result.documents.map(\.count) == [2, 1])
    #expect(result.partialMessage == nil)
    #expect(await FakeBackend().listScanners() == FakeScanners.infos)
}
