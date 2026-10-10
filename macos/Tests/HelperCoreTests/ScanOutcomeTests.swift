import Foundation
import Testing
@testable import HelperCore

private let page = PageImage(data: Data([1]), dpi: 300)

private func status(_ block: () throws -> Void) -> ProtocolError? {
    do { try block(); return nil } catch let error as ProtocolError { return error } catch { return ProtocolError(-1, "") }
}

@Test func pagesWithoutError() throws {
    let result = try ScanOutcome.documents(pages: [page, page], errorMessage: nil, source: .feeder)
    #expect(result.documents.count == 1 && result.documents[0].count == 2)
    #expect(result.partialMessage == nil)
}

@Test func pagesThenError() throws {
    let result = try ScanOutcome.documents(pages: [page], errorMessage: "Paper jam", source: .feeder)
    #expect(result.partialMessage == "The scan stopped after 1 page: Paper jam. The pages before it were kept.")
}

@Test func noPages() {
    #expect(status { _ = try ScanOutcome.documents(pages: [], errorMessage: "Device busy", source: .flatbed) }
            == ProtocolError(500, "The scan failed: Device busy"))
    #expect(status { _ = try ScanOutcome.documents(pages: [], errorMessage: nil, source: .feeder) }
            == ProtocolError(500, "No paper in the feeder."))
    #expect(status { _ = try ScanOutcome.documents(pages: [], errorMessage: nil, source: .flatbed) }
            == ProtocolError(500, "The scanner returned no pages."))
}
