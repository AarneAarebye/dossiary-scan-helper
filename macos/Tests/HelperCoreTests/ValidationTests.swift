import Foundation
import Testing
@testable import HelperCore

private func json(_ text: String) -> Any { try! JSONBody.parse(Data(text.utf8)) }

private func status(_ text: String) -> Int? {
    do {
        _ = try ScanRequestValidator.validate(json(text), scanners: FakeScanners.infos)
        return nil
    } catch let error as ProtocolError {
        #expect(!error.message.isEmpty)
        return error.status
    } catch {
        return -1
    }
}

private let ocrScanner = ScannerInfo(id: "s:ocr", name: "OCR Scanner", sources: [.flatbed], duplex: false,
                                     colorModes: [.color], resolutions: [300], extras: [], ocrLanguages: ["deu", "eng"])
private let plainScanner = ScannerInfo(id: "s:plain", name: "Plain Scanner", sources: [.flatbed], duplex: false,
                                       colorModes: [.color], resolutions: [300], extras: [])

private func ocrStatus(_ body: [String: Any]) -> Int? {
    do { _ = try ScanRequestValidator.validate(body, scanners: [ocrScanner, plainScanner]); return nil }
    catch let error as ProtocolError { return error.status } catch { return -1 }
}

@Test func ocrFieldTypes() {
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": "yes"]) == 400)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": 1]) == 400)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": true, "ocrLanguages": "deu"]) == 400)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": true, "ocrLanguages": [1]]) == 400)
    // Type errors come before 422s.
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": "yes", "ocrLanguages": ["xyz"]]) == 400)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": true, "resolution": 301, "ocrLanguages": [1]]) == 400)
}

@Test func ocrValues() throws {
    #expect(ocrStatus(["scanner": "s:plain", "ocr": true]) == 422)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": true, "ocrLanguages": ["xyz"]]) == 422)
    #expect(ocrStatus(["scanner": "s:plain", "ocr": false]) == nil)
    #expect(ocrStatus(["scanner": "s:plain", "ocrLanguages": ["xyz"]]) == nil)  // type-checked only
    let (_, settings) = try ScanRequestValidator.validate(
        ["scanner": "s:ocr", "ocr": true, "ocrLanguages": ["eng", "deu", "eng"]], scanners: [ocrScanner])
    #expect(settings.ocr)
    #expect(settings.ocrLanguages == ["eng", "deu"])
    let (_, plain) = try ScanRequestValidator.validate(["scanner": "s:ocr"], scanners: [ocrScanner])
    #expect(!plain.ocr && plain.ocrLanguages.isEmpty)
}

@Test func fakeTableHasTheNineScannersInOrder() {
    #expect(FakeScanners.infos.map(\.id) == ["fake:flatbed", "fake:feeder", "fake:splitter", "fake:jam",
                                             "fake:slow", "fake:offline", "fake:empty", "fake:ocr", "fake:photo"])
    let feeder = FakeScanners.infos[1]
    #expect(feeder.name == "Fake Feeder")
    #expect(feeder.sources == [.feeder, .flatbed])
    #expect(feeder.duplex)
    #expect(feeder.colorModes == [.color, .gray, .bw])
    #expect(feeder.resolutions == [150, 300, 600])
    #expect(FakeScanners.infos[2].extras == ["splitOnBlank", "skipBlankPages"])
    let described = feeder.json
    #expect(described["sources"] as? [String] == ["feeder", "flatbed"])
    #expect(described["colorModes"] as? [String] == ["color", "gray", "bw"])
    #expect(described["extras"] as? [String] == [])
}

@Test func missingFieldsUseTheScannerDefaults() throws {
    let (scanner, settings) = try ScanRequestValidator.validate(json(#"{"scanner":"fake:feeder"}"#),
                                                                scanners: FakeScanners.infos)
    #expect(scanner.id == "fake:feeder")
    #expect(settings == ScanSettings(source: .feeder, duplex: false, colorMode: .color, resolution: 150, extras: [:]))
}

@Test func fullRequestIsAccepted() throws {
    let (_, settings) = try ScanRequestValidator.validate(json(#"""
        {"scanner":"fake:feeder","source":"feeder","duplex":true,"colorMode":"gray",
         "resolution":300,"format":"pdf","extras":{"somethingNew":false}}
        """#), scanners: FakeScanners.infos)
    #expect(settings == ScanSettings(source: .feeder, duplex: true, colorMode: .gray, resolution: 300,
                                     extras: ["somethingNew": false]))
}

@Test func malformedRequestsAre400() {
    for body in ["[]", "null", "\"x\"", "{}", #"{"scanner":7}"#, #"{"scanner":null}"#,
                 #"{"scanner":"fake:flatbed","source":1}"#, #"{"scanner":"fake:flatbed","source":null}"#,
                 #"{"scanner":"fake:flatbed","colorMode":["color"]}"#, #"{"scanner":"fake:flatbed","format":["pdf"]}"#,
                 #"{"scanner":"fake:flatbed","resolution":"300"}"#, #"{"scanner":"fake:flatbed","resolution":300.0}"#,
                 #"{"scanner":"fake:flatbed","resolution":3e2}"#, #"{"scanner":"fake:flatbed","resolution":true}"#,
                 #"{"scanner":"fake:flatbed","duplex":1}"#, #"{"scanner":"fake:flatbed","duplex":"true"}"#,
                 #"{"scanner":"fake:flatbed","extras":[]}"#, #"{"scanner":"fake:flatbed","extras":{"splitOnBlank":1}}"#] {
        #expect(status(body) == 400, "\(body)")
    }
}

@Test func unknownScannerIs404() {
    #expect(status(#"{"scanner":"fake:nope"}"#) == 404)
}

@Test func unsupportedValuesAre422() {
    for body in [#"{"scanner":"fake:flatbed","source":"feeder"}"#, #"{"scanner":"fake:flatbed","source":"glass"}"#,
                 #"{"scanner":"fake:flatbed","colorMode":"sepia"}"#, #"{"scanner":"fake:flatbed","resolution":299}"#,
                 #"{"scanner":"fake:flatbed","format":"tiff"}"#, #"{"scanner":"fake:flatbed","duplex":true}"#,
                 #"{"scanner":"fake:feeder","source":"flatbed","duplex":true}"#,
                 #"{"scanner":"fake:flatbed","extras":{"splitOnBlank":true}}"#] {
        #expect(status(body) == 422, "\(body)")
    }
}

@Test func areaMustBeText() {
    for body in [#"{"scanner":"fake:flatbed","area":5}"#, #"{"scanner":"fake:flatbed","area":["a4"]}"#,
                 #"{"scanner":"fake:flatbed","area":null}"#] {
        #expect(status(body) == 400, "\(body)")
    }
    // A wrong area type beats a 422 for another field.
    #expect(status(#"{"scanner":"fake:flatbed","area":5,"resolution":1200}"#) == 400)
}

@Test func anyAreaIs422() throws {
    for body in [#"{"scanner":"fake:flatbed","area":"a4"}"#, #"{"scanner":"fake:feeder","area":"10x15"}"#,
                 #"{"scanner":"fake:flatbed","area":""}"#] {
        #expect(status(body) == 422, "\(body)")
    }
    do {
        _ = try ScanRequestValidator.validate(json(#"{"scanner":"fake:flatbed","area":"a4"}"#),
                                              scanners: FakeScanners.infos)
        Issue.record("an area was accepted")
    } catch let error as ProtocolError {
        #expect(error.message == "Fake Flatbed has no scan areas.")
    }
}

@Test func requestWithoutAreaIsUnaffected() throws {
    #expect(status(#"{"scanner":"fake:flatbed"}"#) == nil)
    let (_, settings) = try ScanRequestValidator.validate(json(#"{"scanner":"fake:flatbed","resolution":300}"#),
                                                          scanners: FakeScanners.infos)
    #expect(settings == ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 300, extras: [:]))
}

@Test func checksRunInProtocolOrder() {
    #expect(status(#"{"scanner":"fake:nope","source":1}"#) == 404)            // unknown scanner beats wrong type
    #expect(status(#"{"scanner":"fake:flatbed","source":1,"resolution":299}"#) == 400)  // wrong type beats 422
}

@Test func emptyAndInvalidBodies() throws {
    #expect(throws: ProtocolError.self) { try JSONBody.parse(Data("{not json".utf8)) }
    #expect(try JSONBody.parse(Data()) is NSNull)
}

@Test func jsonNumberHelpers() {
    #expect(JSONBody.integer(json("300")) == 300)
    #expect(JSONBody.integer(json("300.0")) == nil)
    #expect(JSONBody.integer(json("true")) == nil)
    #expect(JSONBody.bool(json("true")) == true)
    #expect(JSONBody.bool(json("1")) == nil)
}

private let photoScanner = ScannerInfo(
    id: "s:photo", name: "Photo Scanner", sources: [.flatbed, .feeder], duplex: false,
    colorModes: [.color, .gray, .bw], resolutions: [150, 300, 600, 1200], extras: [],
    formats: ["pdf", "jpeg", "png"], areas: ["full", "a4", "10x15"], fullAreaMM: SizeMM(width: 216, height: 297))
private let photoOcrScanner = ScannerInfo(
    id: "s:photo-ocr", name: "Photo OCR Scanner", sources: [.flatbed], duplex: false, colorModes: [.color],
    resolutions: [300], extras: [], ocrLanguages: ["deu", "eng"], formats: ["pdf", "jpeg"], areas: ["a4"])
private let unknownGlass = ScannerInfo(
    id: "s:unknown", name: "Unknown Glass", sources: [.flatbed], duplex: false, colorModes: [.color],
    resolutions: [300, 1200], extras: [], formats: ["pdf", "jpeg"], areas: ["full"])

private func photo(_ body: [String: Any], scanners: [ScannerInfo]? = nil) throws -> ScanSettings {
    try ScanRequestValidator.validate(body, scanners: scanners ?? [photoScanner, photoOcrScanner, unknownGlass]).1
}

private func photoError(_ body: [String: Any]) -> ProtocolError? {
    do { _ = try photo(body); return nil } catch let error as ProtocolError { return error } catch { return nil }
}

@Test func aRequestWithoutFormatOrAreaGetsPdfAndTheFirstArea() throws {
    let settings = try photo(["scanner": "s:photo"])
    #expect(settings.format == "pdf" && settings.area == "full")
    let plain = try ScanRequestValidator.validate(["scanner": "fake:flatbed"], scanners: FakeScanners.infos).1
    #expect(plain.format == "pdf" && plain.area == nil)
}

@Test func anImageRequestIsAccepted() throws {
    let settings = try photo(["scanner": "s:photo", "format": "jpeg", "area": "10x15", "resolution": 1200])
    #expect(settings.format == "jpeg" && settings.area == "10x15" && settings.resolution == 1200)
    _ = try photo(["scanner": "s:photo", "format": "png", "colorMode": "bw", "area": "a4", "resolution": 600])
    _ = try photo(["scanner": "s:photo", "source": "feeder"])  // a PDF from the feeder is fine
}

@Test func unsupportedImageRequestsAre422WithTheirOwnMessages() {
    let cases: [([String: Any], String)] = [
        (["scanner": "s:photo", "format": "tiff"], "Photo Scanner can't make tiff files; it offers pdf, jpeg, png."),
        (["scanner": "s:photo", "area": "a5"], "Photo Scanner doesn't offer the area “a5”."),
        (["scanner": "s:photo", "format": "jpeg", "colorMode": "bw"], "JPEG can't be black and white; use PNG or PDF."),
        (["scanner": "s:photo", "format": "png", "source": "feeder"], "Images can only be scanned from the flatbed."),
        (["scanner": "s:photo", "format": "jpeg", "source": "feeder"], "Images can only be scanned from the flatbed."),
        (["scanner": "s:photo-ocr", "format": "jpeg", "ocr": true], "A searchable PDF can't be made from an image; scan to PDF instead."),
        (["scanner": "s:photo", "area": "a4", "resolution": 1200],
         "A4 at 1200 dpi is too large (139 megapixels; the limit is 100): choose a smaller area or a lower resolution."),
        (["scanner": "s:photo", "area": "full", "resolution": 1200],
         "The whole glass at 1200 dpi is too large (143 megapixels; the limit is 100): choose a smaller area or a lower resolution."),
        (["scanner": "fake:flatbed", "format": "jpeg"], "Fake Flatbed can't make jpeg files; it offers pdf."),
    ]
    for (body, message) in cases {
        let scanners = body["scanner"] as? String == "fake:flatbed" ? FakeScanners.infos : [photoScanner, photoOcrScanner]
        do {
            _ = try ScanRequestValidator.validate(body, scanners: scanners)
            Issue.record("accepted: \(body)")
        } catch let error as ProtocolError {
            #expect(error.status == 422 && error.message == message, "\(body): \(error.message)")
        } catch {
            Issue.record("unexpected error for \(body)")
        }
    }
}

@Test func anAreaWhoseSizeIsUnknownSkipsTheLimitCheck() throws {
    let settings = try photo(["scanner": "s:unknown", "format": "jpeg", "area": "full", "resolution": 1200])
    #expect(settings.area == "full")
}

@Test func theSizeLimitCountsTheScannersRealGlassForFull() throws {
    _ = try photo(["scanner": "s:photo", "area": "full", "resolution": 600])  // 36 megapixels: fine
}

@Test func wrongTypesAre400BeforeAnyPhoto422() {
    #expect(photoError(["scanner": "s:photo", "area": 5, "format": "jpeg", "colorMode": "bw"])?.status == 400)
    #expect(photoError(["scanner": "s:photo", "format": ["jpeg"], "area": "a5"])?.status == 400)
}
