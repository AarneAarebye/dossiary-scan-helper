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

@Test func fakeTableHasTheEightScannersInOrder() {
    #expect(FakeScanners.infos.map(\.id) == ["fake:flatbed", "fake:feeder", "fake:splitter", "fake:jam",
                                             "fake:slow", "fake:offline", "fake:empty", "fake:ocr"])
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
