import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Joins page images into one PDF, each page sized from its pixels and dpi. JPEG pages are embedded as is.
/// One recognized line of text: `box` is normalized (0…1), origin bottom-left, as Vision and PDF both use.
public struct OcrLine: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public init(text: String, box: CGRect) { self.text = text; self.box = box }
}

public enum PdfBuilder {
    public static func makePdf(_ pages: [PageImage], text: [[OcrLine]]? = nil) throws -> Data {
        guard !pages.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ProtocolError(500, "Couldn't create the PDF.")
        }
        for (index, page) in pages.enumerated() {
            guard let source = CGImageSourceCreateWithData(page.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ProtocolError(500, "A scanned page couldn't be read.")
            }
            let dpi = Double(max(page.dpi, 1))
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            if let lines = text?[safe: index] { drawInvisible(lines, in: box, context: context) }
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }

    /// Each line as invisible text (text drawing mode invisible), stretched to its box's width. CoreText falls
    /// back to a system font for scripts Helvetica lacks (Chinese), and CoreGraphics writes a ToUnicode map, so
    /// PDF readers can search and copy it.
    static func drawInvisible(_ lines: [OcrLine], in box: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let rect = CGRect(x: line.box.minX * box.width, y: line.box.minY * box.height,
                              width: line.box.width * box.width, height: line.box.height * box.height)
            guard rect.width > 0, rect.height > 0 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
            let attributed = NSAttributedString(string: line.text,
                                                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let scale = natural > 0 ? rect.width / natural : 1
            context.textMatrix = CGAffineTransform(scaleX: scale, y: 1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }
}

extension Array {
    /// The element at `index`, or nil when out of range. Used by PdfBuilder, FakeOcrEngine and ScanResponse.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
