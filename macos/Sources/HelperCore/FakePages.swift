import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoding {
    public static func jpeg(_ image: CGImage, quality: Double = 0.8) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProtocolError(500, "Couldn't encode a page.")
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProtocolError(500, "Couldn't encode a page.") }
        return output as Data
    }

    public static func png(_ image: CGImage) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// The scanned file as `format` ("jpeg" or "png") with the dpi set: returned unchanged when it already is
    /// that type and carries that dpi, re-encoded with ImageIO otherwise (some drivers ignore the requested file type).
    public static func normalized(_ data: Data, as format: String, dpi: Int) throws -> Data {
        let type = format == "png" ? UTType.png : UTType.jpeg
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProtocolError(500, "Couldn't read the scanned image.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasRightDPI = abs((properties?[kCGImagePropertyDPIWidth] as? Double ?? 0) - Double(dpi)) < 1
        if (CGImageSourceGetType(source) as String?) == type.identifier && hasRightDPI { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ProtocolError(500, "Couldn't encode the scanned image.")
        }
        var options: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format != "png" { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProtocolError(500, "Couldn't encode the scanned image.") }
        return output as Data
    }
}

/// The fake scanners' pages: an A4 page at a low resolution with one line of text ("" = blank).
public enum FakePages {
    public static let dpi = 50
    static let width = 413   // 8.27 in × 50 dpi
    static let height = 585  // 11.69 in × 50 dpi

    public static func render(_ text: String) throws -> PageImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ProtocolError(500, "Couldn't draw a page.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !text.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 36, y: height - 72)
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { throw ProtocolError(500, "Couldn't draw a page.") }
        return PageImage(data: try ImageEncoding.jpeg(image), dpi: dpi)
    }
}
