import Testing
@testable import HelperCore

@Test func visionLanguageMapping() {
    #expect(OcrLanguages.visionLanguage(for: "deu") == "de-DE")
    #expect(OcrLanguages.visionLanguage(for: "chi_tra") == "zh-Hant")
    #expect(OcrLanguages.visionLanguage(for: "xyz") == nil)
}

@Test func offeredFollowsVisionSupport() {
    #expect(OcrLanguages.offered(supportedVision: ["en-US", "de-DE", "ja-JP"]) == ["deu", "eng"])
    #expect(OcrLanguages.offered(supportedVision: []) == [])
    #expect(OcrLanguages.offered(supportedVision: OcrLanguages.all.map(\.vision)) ==
            ["deu", "eng", "fra", "spa", "chi_sim", "chi_tra"])
}

@Test func visionLanguagesKeepOrderAndDefault() {
    #expect(OcrLanguages.visionLanguages(for: ["eng", "deu"]) == ["en-US", "de-DE"])
    #expect(OcrLanguages.visionLanguages(for: []) == ["de-DE", "en-US"])
}

@Test func scannerJsonHasOcrOnlyWhenOffered() {
    var info = ScannerInfo(id: "x", name: "X", sources: [.flatbed], duplex: false, colorModes: [.color],
                           resolutions: [300], extras: [])
    #expect(info.json["ocr"] == nil)
    info.ocrLanguages = ["deu", "eng"]
    #expect((info.json["ocr"] as? [String: Any])?["languages"] as? [String] == ["deu", "eng"])
}
