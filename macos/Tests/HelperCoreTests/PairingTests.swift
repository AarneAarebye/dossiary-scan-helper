import Foundation
import Testing
@testable import HelperCore

final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { date += seconds }
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("pairing-\(UUID().uuidString)")
        .appendingPathComponent("paired-browsers.json")
}

private func status(_ block: () throws -> Void) -> Int? {
    do { try block(); return nil } catch let error as ProtocolError { return error.status } catch { return -1 }
}

@Test func fakeModeAcceptsZerosAnyNumberOfTimes() throws {
    let store = PairingStore(mode: .fake)
    let first = try store.pair(code: "000000", client: nil)
    let second = try store.pair(code: "000000", client: "Chrome")
    #expect(first != second)
    #expect(first.count >= 22)
    #expect(first.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
    #expect(store.isValid(token: first) && store.isValid(token: second))
    #expect(!store.isValid(token: "nope") && !store.isValid(token: nil))
    #expect(status { _ = try store.pair(code: "000001", client: nil) } == 403)
    #expect(store.openWindow() == "000000")
}

@Test func realModeRefusesWithoutAWindow() {
    let store = PairingStore(mode: .real(fileURL: tempFile()), makeCode: { "123456" })
    #expect(status { _ = try store.pair(code: "123456", client: nil) } == 403)
}

@Test func realModeRightCodePairsOnceAndClosesTheWindow() throws {
    let store = PairingStore(mode: .real(fileURL: tempFile()), makeCode: { "123456" })
    #expect(store.openWindow() == "123456")
    #expect(store.activeCode == "123456")
    let token = try store.pair(code: "123456", client: "Chrome")
    #expect(store.isValid(token: token))
    #expect(store.activeCode == nil)
    #expect(status { _ = try store.pair(code: "123456", client: nil) } == 403)
}

@Test func codeExpiresAfterTwoMinutes() {
    let clock = TestClock()
    let store = PairingStore(mode: .real(fileURL: tempFile()), now: { clock.date }, makeCode: { "123456" })
    _ = store.openWindow()
    #expect(store.secondsLeft == 120)
    clock.advance(119)
    #expect(store.activeCode == "123456")
    clock.advance(1)
    #expect(store.activeCode == nil)
    #expect(status { _ = try store.pair(code: "123456", client: nil) } == 403)
}

@Test func fifthWrongAttemptClosesTheWindow() {
    let store = PairingStore(mode: .real(fileURL: tempFile()), makeCode: { "123456" })
    _ = store.openWindow()
    for _ in 1...4 { #expect(status { _ = try store.pair(code: "000000", client: nil) } == 403) }
    #expect(store.activeCode == "123456")
    #expect(status { _ = try store.pair(code: "000000", client: nil) } == 403)
    #expect(store.activeCode == nil)
    #expect(status { _ = try store.pair(code: "123456", client: nil) } == 403)
}

@Test func tokensPersistHashedAndForgetClearsThem() throws {
    let file = tempFile()
    let store = PairingStore(mode: .real(fileURL: file), makeCode: { "123456" })
    _ = store.openWindow()
    let token = try store.pair(code: "123456", client: "Chrome")
    let saved = try String(contentsOf: file, encoding: .utf8)
    #expect(!saved.contains(token))
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    let reopened = PairingStore(mode: .real(fileURL: file))
    #expect(reopened.isValid(token: token))
    #expect(reopened.pairedCount == 1)
    try reopened.forgetAll()
    #expect(!reopened.isValid(token: token))
    #expect(!PairingStore(mode: .real(fileURL: file)).isValid(token: token))
}

@Test func forgetAllReportsAFailedSaveAndStillForgetsInMemory() throws {
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-blocker-\(UUID().uuidString)")
    try Data("not a folder".utf8).write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }
    let file = blocker.appendingPathComponent("paired-browsers.json")
    let logged = LockedLines()
    let store = PairingStore(mode: .real(fileURL: file), makeCode: { "123456" }, log: { logged.append($0) })
    _ = store.openWindow()
    let token = try store.pair(code: "123456", client: "Chrome")
    #expect(store.isValid(token: token))
    #expect(logged.lines.count == 1)
    #expect(logged.lines.allSatisfy { !$0.contains(token) })

    var thrown: Error?
    do { try store.forgetAll() } catch { thrown = error }
    let error = try #require(thrown as? ProtocolError)
    #expect(error.message.contains("Couldn't update the list of paired browsers"))
    #expect(error.localizedDescription.contains("may still be able to scan"))
    #expect(!store.isValid(token: token))
    #expect(store.pairedCount == 0)
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Test func pairBodyValidation() throws {
    #expect(try PairingStore.validatePairBody(["code": "1"]) == ("1", nil))
    #expect(try PairingStore.validatePairBody(["code": "1", "client": "Chrome"]) == ("1", "Chrome"))
    for body: Any in [NSNull(), [1], [String: Any](), ["code": 1], ["code": "1", "client": 5],
                      ["code": "1", "client": String(repeating: "x", count: 201)]] {
        #expect(status { _ = try PairingStore.validatePairBody(body) } == 400)
    }
    #expect(PairingStore.refusedMessage.contains("Pair a browser"))
}
