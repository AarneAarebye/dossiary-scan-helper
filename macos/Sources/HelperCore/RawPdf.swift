import Foundation

/// A tiny PDF writer for fake:ocr: JPEG pages embedded as is, plus an optional invisible text line in an
/// uncompressed content stream, so the text can be found in the file's bytes (PROTOCOL.md "Fake scanner mode").
/// ASCII text only.
public enum RawPdf {
    public struct Page {
        public let jpeg: Data
        public let widthPx: Int
        public let heightPx: Int
        public let dpi: Int
        public let text: String?
        public init(jpeg: Data, widthPx: Int, heightPx: Int, dpi: Int, text: String?) {
            self.jpeg = jpeg; self.widthPx = widthPx; self.heightPx = heightPx; self.dpi = dpi; self.text = text
        }
    }

    static func number(_ value: Double) -> String { String(format: "%.2f", value) }

    static func escape(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "(", ")", "\\": return "\\" + String(scalar)
            default: return scalar.isASCII && scalar.value >= 32 ? String(scalar) : "?"
            }
        }.joined())
    }

    public static func write(_ pages: [Page]) -> Data {
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: Data) {
            offsets.append(out.count)
            out.append(Data("\(offsets.count) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        func object(_ text: String) { object(Data(text.utf8)) }

        let pageNumbers = pages.indices.map { 4 + $0 * 3 }
        object("<< /Type /Catalog /Pages 2 0 R >>")
        object("<< /Type /Pages /Kids [\(pageNumbers.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>")
        object("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        for (index, page) in pages.enumerated() {
            let number = pageNumbers[index]
            let dpi = Double(max(page.dpi, 1))
            let width = Double(page.widthPx) * 72 / dpi, height = Double(page.heightPx) * 72 / dpi
            object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(RawPdf.number(width)) \(RawPdf.number(height))] "
                   + "/Resources << /Font << /F1 3 0 R >> /XObject << /Im0 \(number + 2) 0 R >> >> "
                   + "/Contents \(number + 1) 0 R >>")
            var content = "q \(RawPdf.number(width)) 0 0 \(RawPdf.number(height)) 0 0 cm /Im0 Do Q\n"
            if let text = page.text {
                content += "BT /F1 12 Tf 3 Tr 36 \(RawPdf.number(height - 48)) Td (\(RawPdf.escape(text))) Tj ET\n"
            }
            object("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
            var image = Data(("<< /Type /XObject /Subtype /Image /Width \(page.widthPx) /Height \(page.heightPx) "
                              + "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode "
                              + "/Length \(page.jpeg.count) >>\nstream\n").utf8)
            image.append(page.jpeg)
            image.append(Data("\nendstream".utf8))
            object(image)
        }
        let xref = out.count
        var trailer = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { trailer += String(format: "%010d 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(trailer.utf8))
        return out
    }
}
