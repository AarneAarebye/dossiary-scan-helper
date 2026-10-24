import Foundation
import Testing
@testable import HelperCore

@Test func theFixedAreasMatchTheProtocol() {
    #expect(Areas.all.map(\.id) == ["a4", "a5", "a6", "10x15", "13x18"])
    #expect(Areas.named("a4")?.widthMM == 210 && Areas.named("a4")?.heightMM == 297)
    #expect(Areas.named("13x18")?.label == "13 x 18 cm" && Areas.named("10x15")?.label == "10 x 15 cm")
    #expect(Areas.named("full") == nil && Areas.named("letter") == nil)
    #expect(Areas.full == "full")
}

@Test func pixelCountRoundsEachSideToWholePixels() {
    #expect(Areas.pixelCount(widthMM: 210, heightMM: 297, dpi: 600) == 4961 * 7016)
    #expect(Areas.pixelCount(widthMM: 100, heightMM: 150, dpi: 1200) == 4724 * 7087)
    #expect(Areas.pixelCount(widthMM: 210, heightMM: 297, dpi: 1200) == 9921 * 14031)
}

@Test func theLimitIsInclusive() {
    #expect(Areas.maxPixels == 100_000_000)
    #expect(!Areas.isOverLimit(100_000_000))
    #expect(Areas.isOverLimit(100_000_001))
}

@Test func fittingAreasForGlassOfDifferentSizes() {
    #expect(Areas.fitting(widthMM: 215.9, heightMM: 297.2) == ["a4", "a5", "a6", "10x15", "13x18"])
    #expect(Areas.fitting(widthMM: 215.9, heightMM: 279.4) == ["a5", "a6", "10x15", "13x18"])  // Letter: A4 is too tall
    #expect(Areas.fitting(widthMM: 209.8, heightMM: 296.8).first == "a4")  // within 0.5 mm counts as fitting
    #expect(Areas.fitting(widthMM: 120, heightMM: 160) == ["a6", "10x15"])
    #expect(Areas.fitting(widthMM: 50, heightMM: 50).isEmpty)
}

@Test func scannerInfoJsonListsFormatsAndAreasOnlyWhenTheyDiffer() {
    let plain = ScannerInfo(id: "a", name: "A", sources: [.flatbed], duplex: false, colorModes: [.color],
                            resolutions: [300], extras: [])
    #expect(plain.formats == ["pdf"] && plain.areas.isEmpty && plain.fullAreaMM == nil)
    #expect(plain.json["formats"] == nil && plain.json["areas"] == nil)
    let photo = ScannerInfo(id: "b", name: "B", sources: [.flatbed], duplex: false, colorModes: [.color],
                            resolutions: [300], extras: [], formats: ["pdf", "jpeg", "png"],
                            areas: ["full", "10x15"], fullAreaMM: SizeMM(width: 216, height: 297))
    #expect(photo.json["formats"] as? [String] == ["pdf", "jpeg", "png"])
    #expect(photo.json["areas"] as? [String] == ["full", "10x15"])
    #expect(photo.json["fullAreaMM"] == nil)  // internal: never in the protocol entry
}

@Test func aRemoteEntryKeepsItsFormatsAndAreas() {
    let entry: [String: Any] = ["id": "sane:canoscan-8800f", "name": "Canon CanoScan 8800F", "sources": ["flatbed"],
                                "duplex": false, "colorModes": ["color", "gray", "bw"],
                                "resolutions": [150, 300, 600, 1200], "extras": [],
                                "formats": ["pdf", "jpeg", "png"], "areas": ["a4", "a5", "10x15"]]
    let info = ScannerInfo(json: entry)
    #expect(info?.formats == ["pdf", "jpeg", "png"] && info?.areas == ["a4", "a5", "10x15"])
    #expect(info?.fullAreaMM == nil)
    let old = ScannerInfo(json: ["id": "x", "name": "X", "sources": ["feeder"]])
    #expect(old?.formats == ["pdf"] && old?.areas.isEmpty == true)
}

@Test func scanSettingsDefaultToPdfAndNoArea() {
    let settings = ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 300, extras: [:])
    #expect(settings.format == "pdf" && settings.area == nil)
    let photo = ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 300, extras: [:],
                             format: "jpeg", area: "10x15")
    #expect(photo.format == "jpeg" && photo.area == "10x15")
}
