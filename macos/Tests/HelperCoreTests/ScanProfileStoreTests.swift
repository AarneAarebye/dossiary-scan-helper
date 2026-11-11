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
