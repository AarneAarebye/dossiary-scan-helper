import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HelperCore

private let stamp = Date(timeIntervalSince1970: 1_761_300_000)

@Test func anImageResultIsOneFileWithOnePageAndAnImagesMessage() throws {
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let result = ScanDocuments(documents: [], partialMessage: nil, image: ImageFile(data: bytes, format: "jpeg"))
    let payload = try ScanResponse.payload(result, date: stamp)
    #expect(payload["ok"] as? Bool == true && payload["partial"] as? Bool == false)
    #expect(payload["message"] as? String == "1 image scanned.")
    let files = try #require(payload["files"] as? [[String: Any]])
    #expect(files.count == 1)
    #expect(files[0]["pages"] as? Int == 1)
    #expect((files[0]["name"] as? String)?.hasPrefix("scan_") == true && (files[0]["name"] as? String)?.hasSuffix(".jpg") == true)
    #expect(files[0]["data"] as? String == bytes.base64EncodedString())
    #expect(files[0]["ocrJob"] == nil)
}

@Test func aPngResultIsNamedPng() throws {
    let result = ScanDocuments(documents: [], partialMessage: nil, image: ImageFile(data: Data([0x89, 0x50]), format: "png"))
    let files = try #require(try ScanResponse.payload(result, date: stamp)["files"] as? [[String: Any]])
    #expect((files[0]["name"] as? String)?.hasSuffix(".png") == true)
}

@Test func pdfResultsKeepTheirPageCountMessage() throws {
    let pages = try ["One", "Two"].map(FakePages.render)
    let payload = try ScanResponse.payload(ScanDocuments(documents: [pages], partialMessage: nil), date: stamp)
    #expect(payload["message"] as? String == "2 pages scanned.")
    #expect((payload["files"] as? [[String: Any]])?.first?["pages"] as? Int == 2)
    #expect(ScanResponse.imagesMessage(1) == "1 image scanned." && ScanResponse.imagesMessage(3) == "3 images scanned.")
}

private func sample() -> CGImage {
    let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
    return context.makeImage()!
}

private func inspect(_ data: Data) -> (type: String?, dpi: Double?, width: Int?) {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return (CGImageSourceGetType(source) as String?, properties?[kCGImagePropertyDPIWidth] as? Double,
            properties?[kCGImagePropertyPixelWidth] as? Int)
}

@Test func aJpegWithTheWrongDpiGetsTheRequestedOne() throws {
    let plain = try ImageEncoding.jpeg(sample())
    let fixed = try ImageEncoding.normalized(plain, as: "jpeg", dpi: 600)
    let info = inspect(fixed)
    #expect(info.type == UTType.jpeg.identifier && info.width == 20)
    #expect(abs((info.dpi ?? 0) - 600) < 1)
}

@Test func aFileOfTheWrongTypeIsReencoded() throws {
    let png = ImageEncoding.png(sample())
    #expect(inspect(png).type == UTType.png.identifier)
    let jpeg = try ImageEncoding.normalized(png, as: "jpeg", dpi: 300)
    #expect(inspect(jpeg).type == UTType.jpeg.identifier && inspect(jpeg).width == 20)
    let back = try ImageEncoding.normalized(jpeg, as: "png", dpi: 300)
    #expect(inspect(back).type == UTType.png.identifier)
}

@Test func aFileThatIsAlreadyRightIsReturnedUnchanged() throws {
    let once = try ImageEncoding.normalized(try ImageEncoding.jpeg(sample()), as: "jpeg", dpi: 300)
    let twice = try ImageEncoding.normalized(once, as: "jpeg", dpi: 300)
    #expect(once == twice)
}

@Test func unreadableBytesAre500() {
    #expect(throws: ProtocolError.self) { try ImageEncoding.normalized(Data([1, 2, 3]), as: "jpeg", dpi: 300) }
}
