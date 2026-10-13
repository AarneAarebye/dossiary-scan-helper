import Foundation

/// fake:ocr's engine: done 2 seconds after the scan, with the page texts written into a byte-searchable PDF.
public struct FakeOcrEngine: OcrEngine {
    let delay: TimeInterval
    let now: @Sendable () -> Date
    public init(delay: TimeInterval = 2, now: @escaping @Sendable () -> Date = { Date() }) {
        self.delay = delay; self.now = now
    }

    public func makeSearchable(_ input: OcrJobInput) async throws -> Data {
        let wait = input.createdAt.addingTimeInterval(delay).timeIntervalSince(now())
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        let texts = input.fakeTexts ?? []
        return RawPdf.write(input.pages.enumerated().map { index, page in
            RawPdf.Page(jpeg: page.data, widthPx: FakePages.width, heightPx: FakePages.height, dpi: page.dpi,
                        text: texts[safe: index])
        })
    }
}
