import Testing
import UniformTypeIdentifiers
@testable import HelperCore

private let continuous = Array(50...1200)

@Test func ids() {
    #expect(CapabilityMapping.scannerID(persistentID: "P1", uuid: "U1", name: "HP") == "ic:P1")
    #expect(CapabilityMapping.scannerID(persistentID: nil, uuid: "U1", name: "HP") == "ic:U1")
    #expect(CapabilityMapping.scannerID(persistentID: nil, uuid: nil, name: "HP") == "ic:HP")
}

@Test func feederAndFlatbed() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:1", name: "HP ENVY", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [1, 8], resolutions: continuous, preferredResolutions: [300]),
        UnitCapabilities(source: .feeder, duplex: true, bitDepths: [8], resolutions: [150, 300, 600], preferredResolutions: []),
    ]))
    #expect(info.sources == [.feeder, .flatbed])
    #expect(info.duplex)
    #expect(info.colorModes == [.color, .gray, .bw])
    #expect(info.resolutions == [150, 300, 600])
    #expect(info.extras == [])
}

@Test func flatbedOnlyWithOddResolutions() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:2", name: "Old", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [], resolutions: [72, 144], preferredResolutions: [144]),
    ]))
    #expect(info.sources == [.flatbed])
    #expect(!info.duplex)
    #expect(info.colorModes == [.color, .gray])
    #expect(info.resolutions == [144])
}

@Test func noUsableUnits() {
    #expect(CapabilityMapping.scannerInfo(id: "ic:3", name: "Film", units: []) == nil)
}

@Test func unitsWithoutCommonResolutionsUseTheFirst() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:4", name: "X", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [8], resolutions: [600], preferredResolutions: []),
        UnitCapabilities(source: .feeder, duplex: false, bitDepths: [8], resolutions: [200], preferredResolutions: []),
    ]))
    #expect(info.resolutions == [600])
    #expect(CapabilityMapping.scannerInfo(id: "ic:5", name: "Y", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [8], resolutions: [], preferredResolutions: []),
    ])?.resolutions == [300])
}

@Test func aFlatbedListsImagesAndTheAreasThatFit() throws {
    let a4Glass = SizeMM(width: 215.9, height: 297.2)
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:p1", name: "HP", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [1, 8], resolutions: continuous,
                         preferredResolutions: [300], physicalSizeMM: a4Glass),
        UnitCapabilities(source: .feeder, duplex: true, bitDepths: [8], resolutions: [150, 300, 600],
                         preferredResolutions: []),
    ]))
    #expect(info.formats == ["pdf", "jpeg", "png"])
    #expect(info.areas == ["full", "a4", "a5", "a6", "10x15", "13x18"])
    #expect(info.fullAreaMM == a4Glass)
}

@Test func letterGlassHasNoA4() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:p2", name: "US", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [8], resolutions: [300],
                         preferredResolutions: [], physicalSizeMM: SizeMM(width: 215.9, height: 279.4)),
    ]))
    #expect(info.areas == ["full", "a5", "a6", "10x15", "13x18"])
}

@Test func aFlatbedWithoutASizeListsOnlyFull() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:p3", name: "Odd", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [8], resolutions: [300], preferredResolutions: []),
    ]))
    #expect(info.formats == ["pdf", "jpeg", "png"] && info.areas == ["full"] && info.fullAreaMM == nil)
}

@Test func aFeederOnlyScannerStaysPdfOnly() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:p4", name: "Sheet", units: [
        UnitCapabilities(source: .feeder, duplex: true, bitDepths: [8], resolutions: [300], preferredResolutions: []),
    ]))
    #expect(info.formats == ["pdf"] && info.areas.isEmpty && info.fullAreaMM == nil)
    #expect(info.json["formats"] == nil && info.json["areas"] == nil)
}

@Test func theFileTypeFollowsTheFormat() {
    #expect(CapabilityMapping.documentType(format: "jpeg", colorMode: .gray) == .jpeg)
    #expect(CapabilityMapping.documentType(format: "png", colorMode: .color) == .png)
    #expect(CapabilityMapping.documentType(format: "pdf", colorMode: .color) == .jpeg)  // pages for the PDF
    #expect(CapabilityMapping.documentType(format: "pdf", colorMode: .bw) == .png)      // JPEG can't hold 1-bit
}

@Test func theScanAreaInInches() {
    let glass = (width: 8.5, height: 11.69)
    #expect(CapabilityMapping.scanAreaInches(area: nil, glass: glass) == glass)
    #expect(CapabilityMapping.scanAreaInches(area: "full", glass: glass) == glass)
    let photo = CapabilityMapping.scanAreaInches(area: "10x15", glass: glass)
    #expect(abs(photo.width - 100 / 25.4) < 1e-9 && abs(photo.height - 150 / 25.4) < 1e-9)
    // An area bigger than the glass is clamped to it.
    let small = (width: 4.0, height: 5.0)
    #expect(CapabilityMapping.scanAreaInches(area: "a4", glass: small) == small)
    #expect(CapabilityMapping.scanAreaInches(area: "unknown", glass: glass) == glass)
}
