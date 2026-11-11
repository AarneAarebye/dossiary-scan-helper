import Foundation
import Testing
@testable import HelperCore

private let imageExtensions = ["pdf", "jpg", "png"]

private func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-file-save-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func safeNameKeepsAnAllowedImageSuffix() {
    #expect(ButtonScanFolder.safeName("scan_1.jpg", extensions: imageExtensions) == "scan_1.jpg")
    #expect(ButtonScanFolder.safeName("scan_1.PNG", extensions: imageExtensions) == "scan_1.PNG")
}

@Test func safeNameAddsTheFirstExtensionWhenNoneMatches() {
    #expect(ButtonScanFolder.safeName("scan", extensions: imageExtensions) == "scan.pdf")
    #expect(ButtonScanFolder.safeName("scan.txt", extensions: ["jpg"]) == "scan.txt.jpg")
}

@Test func safeNameDefaultStaysPdfOnly() {
    #expect(ButtonScanFolder.safeName("a.jpg") == "a.jpg.pdf")
    #expect(ButtonScanFolder.safeName("") == "scan.pdf")
}

@Test func safeNameCutsALongImageNameAndKeepsItsSuffix() {
    let name = String(repeating: "a", count: 300) + ".jpg"
    let safe = ButtonScanFolder.safeName(name, extensions: imageExtensions)
    #expect(safe.utf8.count <= 200)
    #expect(safe.hasSuffix(".jpg"))
}

@Test func saveGoesIntoTheGivenFolderAndNeverOverwrites() throws {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = ButtonScanFolder(defaults: UserDefaults(suiteName: "scan-file-save-\(UUID().uuidString)")!,
                                  fallback: tempFolder())
    let first = try writer.save(Data("one".utf8), named: "scan.jpg", into: folder, extensions: imageExtensions)
    let second = try writer.save(Data("two".utf8), named: "scan.jpg", into: folder, extensions: imageExtensions)
    #expect(first.lastPathComponent == "scan.jpg")
    #expect(second.lastPathComponent == "scan 2.jpg")
    #expect(try Data(contentsOf: first) == Data("one".utf8))
    #expect(first.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
}
