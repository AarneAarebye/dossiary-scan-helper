import Foundation
import Testing
@testable import HelperCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)").appendingPathComponent("profiles.json")
}

private func sample(_ name: String) -> ScanProfile {
    ScanProfile(name: name, scannerID: "fake:flatbed", scannerName: "Fake Flatbed", destination: "/tmp/scans",
                source: .flatbed, colorMode: .color, resolution: 300)
}

@Test func savedProfilesSurviveARestart() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = ScanProfileStore(fileURL: file)
    try store.save(sample("Letters"))
    try store.save(sample("Photos"))
    let again = ScanProfileStore(fileURL: file)
    #expect(again.profiles.map(\.name) == ["Letters", "Photos"])
}

@Test func savingAnExistingIdReplacesIt() throws {
    let store = ScanProfileStore(fileURL: nil)
    var p = sample("Letters")
    try store.save(p)
    p.name = "Letters 2"
    try store.save(p)
    #expect(store.profiles.count == 1)
    #expect(store.profile(id: p.id)?.name == "Letters 2")
}

@Test func removingAProfileForgetsIt() throws {
    let store = ScanProfileStore(fileURL: nil)
    let p = sample("Letters")
    try store.save(p)
    try store.remove(id: p.id)
    #expect(store.profiles.isEmpty)
    #expect(store.profile(id: p.id) == nil)
}

@Test func anUnreadableFileIsMovedAsideAndTheStoreStartsEmpty() throws {
    let file = tempFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try Data("not json".utf8).write(to: file)
    let store = ScanProfileStore(fileURL: file)
    #expect(store.profiles.isEmpty)
    let aside = file.deletingLastPathComponent().appendingPathComponent("profiles.json.unreadable")
    #expect(FileManager.default.fileExists(atPath: aside.path))
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func aFailedWriteLeavesTheStoreUnchanged() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let blocker = dir.appendingPathComponent("blocker")
    try Data("x".utf8).write(to: blocker)
    let store = ScanProfileStore(fileURL: blocker.appendingPathComponent("profiles.json"))
    #expect(throws: (any Error).self) { try store.save(sample("Letters")) }
    #expect(store.profiles.isEmpty)
}

@Test func aProfileFileFrom07xLoadsWithTheSwitchOff() throws {
    let json = """
    {"id":"A","name":"Old","scannerID":"fake:flatbed","scannerName":"Fake Flatbed","destination":"/tmp/scans","source":"flatbed","duplex":false,"colorMode":"color","resolution":300,"format":"pdf","ocr":false,"ocrLanguages":[]}
    """
    let p = try JSONDecoder().decode(ScanProfile.self, from: Data(json.utf8))
    #expect(p.sendToDossiary == false && p.name == "Old" && p.area == nil)
}

@Test func theSendToDossiarySwitchRoundTripsAndIsWritten() throws {
    var p = sample("Letters"); p.sendToDossiary = true
    let data = try JSONEncoder().encode(p)
    #expect(try JSONDecoder().decode(ScanProfile.self, from: data) == p)
    #expect(String(decoding: data, as: UTF8.self).contains("\"sendToDossiary\":true"))
}
