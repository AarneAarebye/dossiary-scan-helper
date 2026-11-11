import Foundation
import Testing
@testable import HelperCore

/// What scanix500-server lists for the Canon CanoScan 8800F on a Pi.
private let flatbedPi = ScannerInfo(
    id: "remote:srv:sane:canoscan-8800f", name: "Canon CanoScan 8800F (node-000)", sources: [.flatbed], duplex: false,
    colorModes: [.color, .gray, .bw], resolutions: [150, 300, 600, 1200], extras: [], ocrLanguages: ["deu", "eng"],
    formats: ["pdf", "jpeg", "png"], areas: ["full", "a4", "a5", "a6", "10x15", "13x18"])

/// …and for the iX500.
private let feederPi = ScannerInfo(
    id: "remote:srv:sane:ix500", name: "ScanSnap iX500 (node-000)", sources: [.feeder], duplex: true,
    colorModes: [.color, .gray, .bw], resolutions: [150, 200, 300, 400, 600], extras: ["splitOnBlank"],
    ocrLanguages: ["deu", "eng"], formats: ["pdf"], areas: [])

private func profile(_ scanner: ScannerInfo, source: Source = .flatbed, duplex: Bool = false, color: ColorMode = .color,
                     resolution: Int = 300, format: String = "pdf", area: String? = nil, ocr: Bool = false,
                     languages: [String] = []) -> ScanProfile {
    ScanProfile(name: "p", scannerID: scanner.id, scannerName: scanner.name, destination: "/tmp/x", source: source,
                duplex: duplex, colorMode: color, resolution: resolution, format: format, area: area, ocr: ocr,
                ocrLanguages: languages)
}

@Test func aFlatbedOffersImagesButNoJpegInBlackAndWhite() {
    #expect(ScanProfileRules.options(for: flatbedPi, source: .flatbed, colorMode: .color).formats == ["pdf", "jpeg", "png"])
    #expect(ScanProfileRules.options(for: flatbedPi, source: .flatbed, colorMode: .bw).formats == ["pdf", "png"])
}

@Test func aFeederOffersOnlyPdfAndDuplex() {
    let options = ScanProfileRules.options(for: feederPi, source: .feeder, colorMode: .color)
    #expect(options.formats == ["pdf"])
    #expect(options.duplexOffered)
    #expect(options.areas.isEmpty)
    #expect(!ScanProfileRules.options(for: flatbedPi, source: .flatbed, colorMode: .color).duplexOffered)
}

@Test func normalizingDropsWhatTheScannerCannot() {
    let p = ScanProfileRules.normalized(profile(flatbedPi, duplex: true, resolution: 250, format: "jpeg", area: "nope",
                                                ocr: true, languages: ["fra"]), for: flatbedPi)
    #expect(!p.duplex)                       // a flatbed has no duplex
    #expect(p.resolution == 300)             // nearest offered
    #expect(p.area == "full")                // unknown area -> the first offered
    #expect(!p.ocr && p.ocrLanguages.isEmpty)   // OCR is only for PDF
    #expect(p.format == "jpeg")
}

@Test func normalizingFixesJpegInBlackAndWhiteAndImagesFromAFeeder() {
    #expect(ScanProfileRules.normalized(profile(flatbedPi, color: .bw, format: "jpeg"), for: flatbedPi).format == "pdf")
    #expect(ScanProfileRules.normalized(profile(feederPi, source: .feeder, format: "png"), for: feederPi).format == "pdf")
}

@Test func normalizingMovesAProfileToAnotherScanner() {
    let p = ScanProfileRules.normalized(profile(flatbedPi, resolution: 1200, format: "png", area: "a4"), for: feederPi)
    #expect(p.scannerID == feederPi.id && p.scannerName == feederPi.name)
    #expect(p.source == .feeder)
    #expect(p.format == "pdf")
    #expect(p.area == nil)
    #expect(p.resolution == 600)
}

@Test func normalizingKeepsAndFiltersOcrLanguages() {
    let kept = ScanProfileRules.normalized(profile(feederPi, source: .feeder, ocr: true, languages: ["eng", "fra"]), for: feederPi)
    #expect(kept.ocr && kept.ocrLanguages == ["eng"])
    let defaulted = ScanProfileRules.normalized(profile(feederPi, source: .feeder, ocr: true, languages: []), for: feederPi)
    #expect(defaulted.ocrLanguages == ["deu", "eng"])
}

@Test func theRequestBodyIsWhatTheValidatorAccepts() throws {
    let cases: [(ScannerInfo, ScanProfile)] = [
        (flatbedPi, profile(flatbedPi, format: "jpeg", area: "a4")),
        (flatbedPi, profile(flatbedPi, color: .bw, resolution: 600, format: "png", area: "10x15")),
        (flatbedPi, profile(flatbedPi, area: "full", ocr: true, languages: ["deu"])),
        (feederPi, profile(feederPi, source: .feeder, duplex: true, ocr: true, languages: ["deu", "eng"])),
    ]
    for (scanner, raw) in cases {
        let p = ScanProfileRules.normalized(raw, for: scanner)
        let body = ScanProfileRules.requestBody(p)
        let (found, settings) = try ScanRequestValidator.validate(body, scanners: [scanner])
        #expect(found.id == scanner.id)
        #expect(settings.format == p.format)
        #expect(settings.ocr == p.ocr)
        #expect(settings.duplex == p.duplex)
    }
}

@Test func theRequestBodyLeavesOutDefaults() {
    let body = ScanProfileRules.requestBody(ScanProfileRules.normalized(profile(feederPi, source: .feeder), for: feederPi))
    #expect(body["format"] == nil && body["area"] == nil && body["ocr"] == nil && body["duplex"] == nil)
    #expect(body["scanner"] as? String == feederPi.id)
}

@Test func aPlaceholderScannerKeepsAProfilesChoices() {
    let p = ScanProfileRules.normalized(profile(flatbedPi, format: "png", area: "a4"), for: flatbedPi)
    let placeholder = ScanProfileRules.placeholderScanner(for: p)
    #expect(placeholder.id == p.scannerID && placeholder.name == p.scannerName)
    #expect(ScanProfileRules.normalized(p, for: placeholder) == p)
}

@Test func normalizingLowersTheResolutionToTheSizeLimit() throws {
    let p = ScanProfileRules.normalized(profile(flatbedPi, resolution: 1200, area: "a4"), for: flatbedPi)
    #expect(p.resolution == 600)
    _ = try ScanRequestValidator.validate(ScanProfileRules.requestBody(p), scanners: [flatbedPi])
}

@Test func aWholeGlassOfUnknownSizeIsNotLimited() {
    #expect(ScanProfileRules.normalized(profile(flatbedPi, resolution: 1200, area: "full"), for: flatbedPi).resolution == 1200)
}

@Test func aKnownWholeGlassIsLimited() throws {
    var scanner = flatbedPi
    scanner.fullAreaMM = SizeMM(width: 216, height: 297)
    let p = ScanProfileRules.normalized(profile(scanner, resolution: 1200, area: "full"), for: scanner)
    #expect(p.resolution == 600)
    _ = try ScanRequestValidator.validate(ScanProfileRules.requestBody(p), scanners: [scanner])
}

@Test func normalizingIsIdempotent() {
    let cases: [(ScannerInfo, ScanProfile)] = [
        (flatbedPi, profile(flatbedPi, duplex: true, resolution: 1200, format: "jpeg", area: "a4", ocr: true, languages: ["fra"])),
        (flatbedPi, profile(flatbedPi, color: .bw, format: "jpeg")),
        (feederPi, profile(flatbedPi, resolution: 1200, format: "png", area: "a4")),
        (feederPi, profile(feederPi, source: .feeder, ocr: true, languages: [])),
    ]
    for (scanner, raw) in cases {
        let once = ScanProfileRules.normalized(raw, for: scanner)
        #expect(ScanProfileRules.normalized(once, for: scanner) == once)
    }
}

@Test func languagesAreDroppedWithoutOcrAndThePlaceholderRoundTrips() {
    let p = ScanProfileRules.normalized(profile(feederPi, source: .feeder, ocr: false, languages: ["eng"]), for: feederPi)
    #expect(p.ocrLanguages.isEmpty)
    #expect(ScanProfileRules.normalized(p, for: ScanProfileRules.placeholderScanner(for: p)) == p)
}
