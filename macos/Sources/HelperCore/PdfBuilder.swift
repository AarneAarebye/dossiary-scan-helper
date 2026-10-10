import CoreGraphics
import Foundation
import ImageIO

/// Joins page images into one PDF, each page sized from its pixels and dpi. JPEG pages are embedded as is.
public enum PdfBuilder {
    public static func makePdf(_ pages: [PageImage]) throws -> Data {
        guard !pages.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ProtocolError(500, "Couldn't create the PDF.")
        }
        for page in pages {
            guard let source = CGImageSourceCreateWithData(page.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ProtocolError(500, "A scanned page couldn't be read.")
            }
            let dpi = Double(max(page.dpi, 1))
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }
}
