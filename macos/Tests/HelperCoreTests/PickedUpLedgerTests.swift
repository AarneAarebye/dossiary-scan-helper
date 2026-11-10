import Foundation
import Testing
@testable import HelperCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("picked-up.json")
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@Test func ledgerRecordsAndReloads() throws {
    let file = tempFile()
    let ledger = PickedUpLedger(fileURL: file)
    #expect(!ledger.contains("a"))
    try ledger.record("a", file: "x.pdf")
    #expect(ledger.contains("a"))
    #expect(PickedUpLedger(fileURL: file).contains("a"))
}

@Test func ledgerPrunesOldEntriesOnTheNextRecord() throws {
    let file = tempFile()
    let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
    let ledger = PickedUpLedger(fileURL: file, clock: { clock.now }, retention: 100)
    try ledger.record("old", file: "o.pdf")
    clock.now = clock.now.addingTimeInterval(50)
    try ledger.record("mid", file: "m.pdf")
    #expect(ledger.contains("old"))
    clock.now = clock.now.addingTimeInterval(80)
    try ledger.record("new", file: "n.pdf")
    #expect(!ledger.contains("old") && ledger.contains("mid") && ledger.contains("new"))
    #expect(!PickedUpLedger(fileURL: file, clock: { clock.now }, retention: 100).contains("old"))
}

@Test func ledgerTreatsMissingOrDamagedFileAsEmpty() throws {
    let file = tempFile()
    #expect(!PickedUpLedger(fileURL: file).contains("a"))
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json{".utf8).write(to: file)
    let ledger = PickedUpLedger(fileURL: file)
    #expect(!ledger.contains("a"))
    try ledger.record("a", file: "x.pdf")
    #expect(PickedUpLedger(fileURL: file).contains("a"))
}

@Test func ledgerWithoutAFileLivesInMemory() throws {
    let ledger = PickedUpLedger(fileURL: nil)
    try ledger.record("a", file: "x.pdf")
    #expect(ledger.contains("a"))
}
