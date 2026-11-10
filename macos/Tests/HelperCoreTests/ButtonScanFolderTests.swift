import Foundation
import Testing
@testable import HelperCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func suite() -> UserDefaults {
    let name = "ButtonScanFolderTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)   // starts empty; nothing is written unless a test chooses
    return defaults
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
    #expect(name.utf8.count == 200 && name.hasSuffix(".pdf"))
}

@Test func safeNameLimitsBytesOfMultiByteCharacters() {
    let name = ButtonScanFolder.safeName(String(repeating: "\u{1F4C4}", count: 100) + ".pdf")
    #expect(name.utf8.count <= 200 && name.hasSuffix(".pdf") && name.hasPrefix("\u{1F4C4}"))
}

@Test func safeNameNeverStartsWithADot() {
    #expect(ButtonScanFolder.safeName(" .x.pdf") == "x.pdf")
    #expect(ButtonScanFolder.safeName("/ .x") == "x.pdf")
    #expect(ButtonScanFolder.safeName(" ... ") == "scan.pdf")
    #expect(ButtonScanFolder.safeName(".") == "scan.pdf")
    #expect(ButtonScanFolder.safeName("..") == "scan.pdf")
    #expect(ButtonScanFolder.safeName(". . x") == "x.pdf" || !ButtonScanFolder.safeName(". . x").hasPrefix("."))
    #expect(!ButtonScanFolder.safeName("...pdf").hasPrefix(".") && ButtonScanFolder.safeName("...pdf").hasSuffix(".pdf"))
}

@Test func safeNameDropsFormatCharacters() {
    #expect(ButtonScanFolder.safeName("a\u{202E}fdp.b\u{200B}c.pdf") == "afdp.bc.pdf")
}

@Test func safeNameReplacesColons() {
    #expect(ButtonScanFolder.safeName("a:b.pdf") == "a-b.pdf")
}

@Test func saveWritesAndNeverOverwrites() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
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
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try ButtonScanFolder(defaults: suite(), fallback: dir).save(Data("x".utf8), named: "../../evil")
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    #expect(url.lastPathComponent == "evil.pdf")
}

@Test func saveMovesOnWhenTheNameIsTakenJustBeforeTheMove() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = ButtonScanFolder(defaults: suite(), fallback: dir)
    let sneaky = Data("other".utf8)
    folder.beforeMove = { _, target in
        if target.lastPathComponent == "x.pdf" { try? sneaky.write(to: target) }
    }
    let url = try folder.save(Data("mine".utf8), named: "x.pdf")
    #expect(url.lastPathComponent == "x 2.pdf")
    #expect(try Data(contentsOf: dir.appendingPathComponent("x.pdf")) == sneaky)
    #expect(try Data(contentsOf: url) == Data("mine".utf8))
}

@Test func theTempFileIsHiddenWhileSaving() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = ButtonScanFolder(defaults: suite(), fallback: dir)
    nonisolated(unsafe) var seen: [String] = []
    folder.beforeMove = { _, _ in
        seen = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }
    _ = try folder.save(Data("x".utf8), named: "x.pdf")
    let visible = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
    #expect(seen.count == 1 && seen[0].hasPrefix(".") && seen[0].hasSuffix(".tmp"))
    #expect(visible == ["x.pdf"])
}

@Test(.enabled(if: getuid() != 0)) func saveFailureThrowsAndLeavesNothing() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
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
    let name = "ButtonScanFolderTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let fallback = tempDir(), chosen = tempDir()
    let folder = ButtonScanFolder(defaults: defaults, fallback: fallback)
    #expect(folder.url == fallback)
    folder.choose(chosen)
    #expect(folder.url.path == chosen.path)
    #expect(ButtonScanFolder(defaults: defaults, fallback: fallback).url.path == chosen.path)
}
