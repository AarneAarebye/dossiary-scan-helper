import Testing
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
