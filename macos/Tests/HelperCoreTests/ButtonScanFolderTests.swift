import Foundation
import Testing
@testable import HelperCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func suite() -> UserDefaults {
    UserDefaults(suiteName: "ButtonScanFolderTests-\(UUID().uuidString)")!
}

@Test func safeNameKeepsAGoodName() {
    #expect(ButtonScanFolder.safeName("scan_2026-11-10_151030.pdf") == "scan_2026-11-10_151030.pdf")
}

@Test func safeNameStripsDirectoriesDotsAndControlCharacters() {
    #expect(ButtonScanFolder.safeName("../../x.pdf") == "x.pdf")
    #expect(ButtonScanFolder.safeName(".hidden.pdf") == "hidden.pdf")
    #expect(ButtonScanFolder.safeName("a\u{0}b\u{7}c.pdf") == "abc.pdf")
}

@Test func safeNameAddsSuffixAndReplacesEmpty() {
    #expect(ButtonScanFolder.safeName("scan") == "scan.pdf")
    #expect(ButtonScanFolder.safeName("") == "scan.pdf")
    #expect(ButtonScanFolder.safeName("...") == "scan.pdf")
    #expect(ButtonScanFolder.safeName("a/") == "scan.pdf")
}

@Test func safeNameLimitsLengthKeepingSuffix() {
    let name = ButtonScanFolder.safeName(String(repeating: "a", count: 300) + ".pdf")
    #expect(name.count == 120 && name.hasSuffix(".pdf"))
}

@Test func saveWritesAndNeverOverwrites() throws {
    let dir = tempDir()
    let folder = ButtonScanFolder(defaults: suite(), fallback: dir)
    let a = try folder.save(Data("one".utf8), named: "x.pdf")
    let b = try folder.save(Data("two".utf8), named: "x.pdf")
    let c = try folder.save(Data("three".utf8), named: "x.pdf")
    #expect(a.lastPathComponent == "x.pdf" && b.lastPathComponent == "x 2.pdf" && c.lastPathComponent == "x 3.pdf")
    #expect(try Data(contentsOf: a) == Data("one".utf8))
    #expect(try Data(contentsOf: b) == Data("two".utf8))
    #expect(try Data(contentsOf: c) == Data("three".utf8))
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(!names.contains { $0.hasSuffix(".tmp") } && names.count == 3)
}

@Test func saveSanitizesTheServerName() throws {
    let dir = tempDir()
    let url = try ButtonScanFolder(defaults: suite(), fallback: dir).save(Data("x".utf8), named: "../../evil")
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    #expect(url.lastPathComponent == "evil.pdf")
}

@Test func saveFailureThrowsAndLeavesNothing() throws {
    let dir = tempDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let folder = ButtonScanFolder(defaults: suite(), fallback: dir)
    do {
        _ = try folder.save(Data("x".utf8), named: "x.pdf")
        Issue.record("expected a failure")
    } catch let error as ButtonScanSaveError {
        #expect(!error.reason.isEmpty)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func urlIsTheFallbackUntilChosenAndSurvivesANewInstance() {
    let defaults = suite(), fallback = tempDir(), chosen = tempDir()
    let folder = ButtonScanFolder(defaults: defaults, fallback: fallback)
    #expect(folder.url == fallback)
    folder.choose(chosen)
    #expect(folder.url.path == chosen.path)
    #expect(ButtonScanFolder(defaults: defaults, fallback: fallback).url.path == chosen.path)
}
