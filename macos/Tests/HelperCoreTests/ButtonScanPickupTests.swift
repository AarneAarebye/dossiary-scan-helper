import Foundation
import Testing
@testable import HelperCore

private func isCannotSave(_ p: ButtonScanProblem?) -> Bool { if case .cannotSave = p { return true }; return false }
private func isCannotRecord(_ p: ButtonScanProblem?) -> Bool { if case .cannotRecord = p { return true }; return false }

private let idA = String(repeating: "a", count: 22)
private let idB = String(repeating: "b", count: 22)

private func pdf(_ text: String = "x") -> Data { Data("%PDF-1.4 \(text)".utf8) }

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A scripted scan server answering /health, the list, the download and DELETE.
private final class Script: @unchecked Sendable {
    struct Item { var id: String, name: String, ocr: String, body: Data, bytes: Int }
    private let lock = NSLock()
    private var _items: [Item] = []
    var buttonScans: Bool? = true
    var healthError: RemoteError?
    var listStatus = 200
    var deleteStatus = 204
    var deleteThrows = false
    var failDownloads: Set<String> = []
    var deleteThrowsCertificate = false
    var hidden = false
    var goneIds: Set<String> = []
    private(set) var deleted: [String] = []

    func add(_ id: String, name: String, ocr: String = "done", body: Data = pdf(), bytes: Int? = nil) {
        lock.withLock { _items.append(Item(id: id, name: name, ocr: ocr, body: body, bytes: bytes ?? body.count)) }
    }
    func setOcr(_ id: String, _ ocr: String) {
        lock.withLock { for i in _items.indices where _items[i].id == id { _items[i].ocr = ocr } }
    }

    func handle(_ r: RemoteRequest) throws -> (Int, Data) {
        if r.path == "/health" {
            if let healthError { throw healthError }
            var object: [String: Any] = ["ok": true]
            if let buttonScans { object["buttonScans"] = buttonScans }
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        if r.path == "/button-scans" {
            if listStatus != 200 { return (listStatus, Data("{}".utf8)) }
            let list = lock.withLock { (hidden ? [] : _items).map { ["id": $0.id, "name": $0.name, "pages": 1, "bytes": $0.bytes,
                                                       "created": "2026-11-10T15:10:30", "ocr": $0.ocr] as [String: Any] } }
            return (200, try JSONSerialization.data(withJSONObject: ["scans": list]))
        }
        if r.path.hasPrefix("/button-scans/") {
            let id = String(r.path.dropFirst("/button-scans/".count))
            if r.method == "DELETE" {
                if deleteThrowsCertificate { throw RemoteError.certificateChanged(seen: "EE") }
                if deleteThrows { throw RemoteError.unreachable("down") }
                if deleteStatus == 204 || deleteStatus == 404 {
                    lock.withLock { _items.removeAll { $0.id == id }; deleted.append(id) }
                }
                return (deleteStatus, Data())
            }
            if goneIds.contains(id) { return (404, Data()) }
            if failDownloads.contains(id) { throw RemoteError.unreachable("down") }
            guard let item = lock.withLock({ _items.first { $0.id == id } }) else { return (404, Data()) }
            return (200, item.body)
        }
        return (404, Data())
    }
}

private struct Rig {
    let script = Script()
    let clock = FakeClock()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder: ButtonScanFolder
    let ledger = PickedUpLedger(fileURL: nil)
    let store: RemoteServerStore
    let server: RemoteServer
    let transport: FakeBinaryTransport
    let picked = Box()
    let logs = Box()
    let pickup: ButtonScanPickup

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _scans: [PickedUpScan] = [], _lines: [String] = []
        func add(_ s: PickedUpScan) { lock.withLock { _scans.append(s) } }
        func add(_ l: String) { lock.withLock { _lines.append(l) } }
        var scans: [PickedUpScan] { lock.withLock { _scans } }
        var lines: [String] { lock.withLock { _lines } }
    }

    init() {
        let name = "ButtonScanPickupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        folder = ButtonScanFolder(defaults: defaults, fallback: dir)
        (store, server) = pairedStore()
        let script = script
        transport = FakeBinaryTransport { try script.handle($0) }
        let transport = transport, clock = clock, picked = picked, logs = logs
        pickup = ButtonScanPickup(store: store, folder: folder, ledger: ledger, transport: { _ in transport },
                                  clock: { clock.now }, onPickedUp: { picked.add($0) }, log: { logs.add($0) })
    }

    func key(_ id: String) -> String { "\(server.id)/\(id)" }
    var paths: [String] { transport.sent.map { "\($0.method) \($0.path)" } }
    var files: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
}

@Test func picksUpASavedScanAndDeletesItAfterwards() async throws {
    let rig = Rig()
    rig.script.add(idA, name: "scan_2026-11-10_151030.pdf", body: pdf("one"))
    await rig.pickup.pickUpOnce()
    #expect(rig.paths == ["GET /health", "GET /button-scans", "GET /button-scans/\(idA)", "DELETE /button-scans/\(idA)"])
    #expect(rig.files == ["scan_2026-11-10_151030.pdf"])
    #expect(try Data(contentsOf: rig.dir.appendingPathComponent("scan_2026-11-10_151030.pdf")) == pdf("one"))
    #expect(rig.ledger.contains(rig.key(idA)))
    #expect(rig.picked.scans.count == 1 && rig.picked.scans.first?.server == "scanner" && rig.picked.scans.first?.pages == 1)
    #expect(rig.pickup.lastScan == rig.picked.scans.first)
    #expect(rig.pickup.lastProblem == nil)
    let sent = rig.transport.sent
    #expect(sent[0].token == nil)
    #expect(sent[1...].allSatisfy { $0.token == "tok-scanner" })
}

@Test func aServerWithoutButtonScansOnlyGetsAHealthRequest() async {
    for flag in [nil, false] as [Bool?] {
        let rig = Rig()
        rig.script.buttonScans = flag
        rig.script.add(idA, name: "a.pdf")
        await rig.pickup.pickUpOnce()
        #expect(rig.paths == ["GET /health"])
    }
}

@Test func troubledServersSaveNothingAndOthersAreStillServed() async {
    let changes: [@Sendable (Script) -> Void] = [
        { $0.healthError = .unreachable("timed out") },
        { $0.healthError = .certificateChanged(seen: "EE") },
        { $0.listStatus = 401 },
    ]
    for change in changes {
        let rig = Rig()
        let good = RemoteServer(name: "good", host: "good.local", port: 8767, fingerprint: String(repeating: "CD", count: 32))
        try! rig.store.add(good, token: "tok-good")
        let goodScript = Script()
        goodScript.add(idB, name: "b.pdf")
        let goodTransport = FakeBinaryTransport { try goodScript.handle($0) }
        let badTransport = rig.transport
        change(rig.script)
        rig.script.add(idA, name: "a.pdf")
        let pickup = ButtonScanPickup(store: rig.store, folder: rig.folder, ledger: rig.ledger,
                                      transport: { $0.id == good.id ? goodTransport : badTransport })
        await pickup.pickUpOnce()
        #expect(rig.files == ["b.pdf"])
        #expect(!rig.ledger.contains(rig.key(idA)) && rig.ledger.contains("\(good.id)/\(idB)"))
        #expect(rig.script.deleted.isEmpty && goodScript.deleted == [idB])
    }
}

@Test func aServerWithoutATokenIsNotContacted() async {
    let rig = Rig()
    let secrets = MemorySecretStore()
    let store = RemoteServerStore(fileURL: nil, secrets: secrets)
    try! store.add(rig.server, token: "t")
    secrets.delete(rig.server.id)
    rig.script.add(idA, name: "a.pdf")
    let transport = rig.transport
    let pickup = ButtonScanPickup(store: store, folder: rig.folder, ledger: rig.ledger, transport: { _ in transport })
    await pickup.pickUpOnce()
    #expect(transport.sent.isEmpty && rig.files.isEmpty)
}

@Test func aPendingScanWaitsThirtyMinutesAndAFailedOneDoesNot() async {
    let rig = Rig()
    rig.script.add(idA, name: "a.pdf", ocr: "pending")
    rig.script.add(idB, name: "b.pdf", ocr: "failed")
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["b.pdf"])
    rig.clock.advance(30 * 60)
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["b.pdf"])
    rig.clock.advance(2)
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["a.pdf", "b.pdf"])
}

@Test func aBadBodyIsNeitherSavedNorDeletedAndIsRetried() async {
    let rig = Rig()
    rig.script.add(idA, name: "a.pdf", body: Data("<html>".utf8))
    rig.script.add(idB, name: "b.pdf", body: pdf("short"), bytes: 999)
    await rig.pickup.pickUpOnce()
    #expect(rig.files.isEmpty)
    #expect(rig.script.deleted.isEmpty)
    #expect(!rig.logs.lines.isEmpty)
    await rig.pickup.pickUpOnce()
    #expect(rig.paths.filter { $0 == "GET /button-scans/\(idA)" }.count == 2)
}

@Test func anInvalidIdIsSkippedWithoutARequestContainingIt() async {
    let rig = Rig()
    let bad = "../../etc/passwd-with-more-chars"
    rig.script.add(bad, name: "evil.pdf")
    rig.script.add("short", name: "short.pdf")
    rig.script.add(idA, name: "a.pdf")
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["a.pdf"])
    #expect(rig.transport.sent.allSatisfy { !$0.path.contains("passwd") && !$0.path.contains("short") })
}

@Test func anUnwritableFolderKeepsTheScanAndTheNextGoodPassClearsTheProblem() async throws {
    let rig = Rig()
    try FileManager.default.createDirectory(at: rig.dir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("file".utf8).write(to: rig.dir)       // a file where the folder should be
    rig.script.add(idA, name: "a.pdf")
    await rig.pickup.pickUpOnce()
    #expect(!rig.paths.contains { $0.hasPrefix("DELETE") })
    #expect(isCannotSave(rig.pickup.lastProblem))
    #expect(!rig.ledger.contains(rig.key(idA)))
    try FileManager.default.removeItem(at: rig.dir)
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["a.pdf"])
    #expect(rig.pickup.lastProblem == nil)
    #expect(rig.script.deleted == [idA])
}

@Test func aFailedDeleteIsRetriedWithoutSavingAgain() async {
    for mode in ["throws", "500"] {
        let rig = Rig()
        rig.script.add(idA, name: "a.pdf")
        if mode == "throws" { rig.script.deleteThrows = true } else { rig.script.deleteStatus = 500 }
        await rig.pickup.pickUpOnce()
        #expect(rig.ledger.contains(rig.key(idA)) && rig.files == ["a.pdf"])
        rig.script.deleteThrows = false; rig.script.deleteStatus = 204
        await rig.pickup.pickUpOnce()
        #expect(rig.files == ["a.pdf"])
        #expect(rig.picked.scans.count == 1)
        #expect(rig.script.deleted == [idA])
        #expect(rig.paths.filter { $0 == "GET /button-scans/\(idA)" }.count == 1)
    }
}

@Test func aDelete404CountsAsSuccess() async {
    let rig = Rig()
    rig.script.add(idA, name: "a.pdf")
    rig.script.deleteStatus = 404
    await rig.pickup.pickUpOnce()
    #expect(rig.pickup.lastProblem == nil && rig.ledger.contains(rig.key(idA)))
    #expect(rig.picked.scans.count == 1)
    #expect(!rig.logs.lines.contains { $0.contains("refused to delete") })
    let failing = Rig()
    failing.script.add(idA, name: "a.pdf")
    failing.script.deleteStatus = 500
    await failing.pickup.pickUpOnce()
    #expect(failing.logs.lines.contains { $0.contains("refused to delete") })
}

@Test func aScanAlreadyInTheLedgerIsOnlyDeleted() async throws {
    let rig = Rig()
    try rig.ledger.record(rig.key(idA), file: "a.pdf")
    rig.script.add(idA, name: "a.pdf")
    await rig.pickup.pickUpOnce()
    #expect(rig.paths == ["GET /health", "GET /button-scans", "DELETE /button-scans/\(idA)"])
    #expect(rig.files.isEmpty && rig.picked.scans.isEmpty)
}

@Test func scansAreTakenOldestFirstAndNameClashesGetANumber() async {
    let rig = Rig()
    rig.script.add(idA, name: "scan.pdf", body: pdf("first"))
    rig.script.add(idB, name: "scan.pdf", body: pdf("second"))
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["scan 2.pdf", "scan.pdf"])
    #expect(rig.picked.scans.map(\.file.lastPathComponent) == ["scan.pdf", "scan 2.pdf"])
    #expect(rig.script.deleted == [idA, idB])
}

private final class CountingTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _health = 0
    var health: Int { lock.withLock { _health } }
    let delay: UInt64
    init(delay: UInt64 = 0) { self.delay = delay }
    func send(_ request: RemoteRequest) async throws -> RemoteReply {
        if request.path == "/health" { lock.withLock { _health += 1 } }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return RemoteReply(status: 200, body: Data(#"{"buttonScans":false}"#.utf8), fingerprint: "")
    }
}

@Test func startRunsPassesUntilStopped() async throws {
    let (store, _) = pairedStore()
    let transport = CountingTransport()
    let pickup = ButtonScanPickup(store: store, folder: ButtonScanFolder(fallback: FileManager.default.temporaryDirectory),
                                  ledger: PickedUpLedger(fileURL: nil), transport: { _ in transport })
    pickup.start(interval: 0.01)
    for _ in 0..<500 where transport.health < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
    pickup.stop()
    #expect(transport.health >= 3)
    try await Task.sleep(nanoseconds: 100_000_000)
    let after = transport.health
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(transport.health == after)
}

@Test func aPassInProgressIsNotStartedTwice() async {
    let (store, _) = pairedStore()
    let transport = CountingTransport(delay: 200_000_000)
    let pickup = ButtonScanPickup(store: store, folder: ButtonScanFolder(fallback: FileManager.default.temporaryDirectory),
                                  ledger: PickedUpLedger(fileURL: nil), transport: { _ in transport })
    async let one: Void = pickup.pickUpOnce()
    async let two: Void = pickup.pickUpOnce()
    _ = await (one, two)
    #expect(transport.health == 1)
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var _entered = 0
    var entered: Int { lock.withLock { _entered } }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resume = lock.withLock { () -> Bool in
                _entered += 1
                if open { return true }
                waiting.append(c); return false
            }
            if resume { c.resume() }
        }
    }
    func release() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true; defer { waiting = [] }; return waiting
        }
        all.forEach { $0.resume() }
    }
}

private final class GatedTransport: RemoteTransport, @unchecked Sendable {
    let inner: FakeBinaryTransport
    let gate = Gate()
    private let lock = NSLock()
    private var gated = false
    init(_ inner: FakeBinaryTransport) { self.inner = inner }
    func gateNext() { lock.withLock { gated = true } }
    func send(_ request: RemoteRequest) async throws -> RemoteReply {
        if lock.withLock({ gated }) { await gate.wait() }
        return try await inner.send(request)
    }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
}

@Test func aFailedLedgerWriteStillAnnouncesDeletesAndNeverSavesTwice() async throws {
    let rig = Rig()
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("file".utf8).write(to: blocker)
    let ledger = PickedUpLedger(fileURL: blocker.appendingPathComponent("picked-up.json"))   // parent is a file
    let transport = rig.transport, picked = rig.picked
    let pickup = ButtonScanPickup(store: rig.store, folder: rig.folder, ledger: ledger, transport: { _ in transport },
                                  onPickedUp: { picked.add($0) })
    rig.script.add(idA, name: "a.pdf")
    await pickup.pickUpOnce()
    #expect(rig.files == ["a.pdf"])
    #expect(rig.script.deleted == [idA])
    #expect(picked.scans.count == 1 && pickup.lastScan != nil)
    #expect(isCannotRecord(pickup.lastProblem))
    rig.script.add(idA, name: "a.pdf")   // the delete is lost: the server lists it again
    await pickup.pickUpOnce()
    #expect(rig.files == ["a.pdf"])
    #expect(picked.scans.count == 1)
}

@Test func aRecordFailureDoesNotStopTheRestOfThePass() async throws {
    let rig = Rig()
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("file".utf8).write(to: blocker)
    let ledger = PickedUpLedger(fileURL: blocker.appendingPathComponent("picked-up.json"))
    let transport = rig.transport
    let pickup = ButtonScanPickup(store: rig.store, folder: rig.folder, ledger: ledger, transport: { _ in transport })
    rig.script.add(idA, name: "a.pdf")
    rig.script.add(idB, name: "b.pdf")
    await pickup.pickUpOnce()
    #expect(rig.files == ["a.pdf", "b.pdf"])
}

@Test func theSaveProblemSurvivesAFailureLaterInTheSamePass() async throws {
    let rig = Rig()
    try FileManager.default.createDirectory(at: rig.dir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("file".utf8).write(to: rig.dir)
    try rig.ledger.record(rig.key(idB), file: "b.pdf")
    rig.script.add(idA, name: "a.pdf")
    rig.script.add(idB, name: "b.pdf")
    rig.script.deleteThrowsCertificate = true
    await rig.pickup.pickUpOnce()
    #expect(isCannotSave(rig.pickup.lastProblem))
}

@Test func aFailedDownloadMovesOnAndThreeErrorsInARowEndTheServersTurn() async {
    let rig = Rig()
    rig.script.add(idA, name: "a.pdf")
    rig.script.add(idB, name: "b.pdf")
    rig.script.failDownloads = [idA]
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["b.pdf"])

    let many = Rig()
    let ids = ["c", "d", "e", "f"].map { String(repeating: $0, count: 22) }
    for id in ids { many.script.add(id, name: "\(id.prefix(1)).pdf") }
    many.script.failDownloads = Set(ids.prefix(3))
    await many.pickup.pickUpOnce()
    #expect(many.files.isEmpty)
    #expect(!many.paths.contains("GET /button-scans/\(ids[3])"))
}

@Test func aCertificateChangeOrA401WhileDeletingEndsTheServersTurn() async {
    let rig = Rig()
    rig.script.add(idA, name: "a.pdf")
    rig.script.add(idB, name: "b.pdf")
    rig.script.deleteThrowsCertificate = true
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["a.pdf"])
    #expect(!rig.paths.contains("GET /button-scans/\(idB)"))
}

@Test func aScanLargerThanTheLimitIsSkippedAndLoggedOnce() async {
    let rig = Rig()
    rig.script.add(idA, name: "a.pdf", bytes: 600 * 1024 * 1024)
    await rig.pickup.pickUpOnce()
    await rig.pickup.pickUpOnce()
    #expect(rig.files.isEmpty)
    #expect(!rig.paths.contains("GET /button-scans/\(idA)"))
    #expect(rig.logs.lines.filter { $0.contains("too large") }.count == 1)
}

@Test func aPendingScanThatDisappearsStartsItsClockAgain() async {
    let rig = Rig()
    rig.script.add(idA, name: "a.pdf", ocr: "pending")
    await rig.pickup.pickUpOnce()
    rig.clock.advance(29 * 60)
    rig.script.hidden = true
    await rig.pickup.pickUpOnce()
    rig.script.hidden = false
    rig.clock.advance(2 * 60)
    await rig.pickup.pickUpOnce()      // first seen again now, not 6 minutes ago
    #expect(rig.files.isEmpty)
    rig.clock.advance(30 * 60 + 1)
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["a.pdf"])
}

@Test func stopDuringAPassKeepsTheProblemAndLetsTheNextPassRun() async throws {
    let rig = Rig()
    try FileManager.default.createDirectory(at: rig.dir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("file".utf8).write(to: rig.dir)
    rig.script.add(idA, name: "a.pdf")
    let gated = GatedTransport(rig.transport)
    let pickup = ButtonScanPickup(store: rig.store, folder: rig.folder, ledger: rig.ledger, transport: { _ in gated })
    await pickup.pickUpOnce()
    let problem = pickup.lastProblem
    #expect(problem != nil)
    try FileManager.default.removeItem(at: rig.dir)

    gated.gateNext()
    pickup.start(interval: 0.01)
    await waitUntil { gated.gate.entered >= 1 }
    pickup.stop()
    #expect(pickup.lastProblem == problem)
    gated.gate.release()
    await waitUntil { rig.files == ["a.pdf"] }
    #expect(pickup.lastProblem == problem)   // the cancelled pass did not touch it
    let before = rig.paths.filter { $0 == "GET /health" }.count
    for _ in 0..<500 {
        await pickup.pickUpOnce()
        if rig.paths.filter({ $0 == "GET /health" }).count > before { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(rig.paths.filter { $0 == "GET /health" }.count > before)
    #expect(pickup.lastProblem == nil)
}

@Test func theTooLargeProblemIsReportedWhileTheScanIsListed() async {
    let rig = Rig()
    rig.script.add(idA, name: "a.pdf", bytes: 600 * 1024 * 1024)
    await rig.pickup.pickUpOnce()
    #expect(rig.pickup.lastProblem == .tooLarge(server: "scanner"))
    #expect(rig.logs.lines.contains(ButtonScanProblem.tooLarge(server: "scanner").logText))
}

@Test func saveReasonsAreSystemDescriptionsNotOurOwnText() async throws {
    let rig = Rig()
    try FileManager.default.createDirectory(at: rig.dir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("file".utf8).write(to: rig.dir)
    rig.script.add(idA, name: "a.pdf")
    await rig.pickup.pickUpOnce()
    guard case .cannotSave(let reason) = rig.pickup.lastProblem else { Issue.record("no save problem"); return }
    #expect(!reason.contains("ButtonScanSaveError") && !reason.isEmpty)
}

@Test func aStoppedPassDoesNotLogUnreachableErrors() async throws {
    let rig = Rig()
    for id in [idA, idB, String(repeating: "c", count: 22)] { rig.script.add(id, name: "\(id.prefix(1)).pdf") }
    rig.script.failDownloads = [idA, idB, String(repeating: "c", count: 22)]
    let inner = rig.transport
    let gated = GatedTransport(inner)
    let logs = rig.logs
    let pickup = ButtonScanPickup(store: rig.store, folder: rig.folder, ledger: rig.ledger, transport: { _ in gated },
                                  log: { logs.add($0) })
    gated.gateNext()
    let task = Task { await pickup.pickUpOnce() }
    await waitUntil { gated.gate.entered >= 1 }
    task.cancel()
    gated.gate.release()
    await task.value
    #expect(!logs.lines.contains { $0.contains("could not be reached") })
}

@Test func truncatedBodiesAreTriedAtMostThreeTimesAPassAndLoggedOncePerScan() async {
    let rig = Rig()
    let ids = ["c", "d", "e", "f"].map { String(repeating: $0, count: 22) }
    for id in ids { rig.script.add(id, name: "\(id.prefix(1)).pdf", body: pdf("cut"), bytes: 9999) }
    await rig.pickup.pickUpOnce()
    #expect(rig.paths.filter { $0.hasPrefix("GET /button-scans/") }.count == 3)
    #expect(rig.logs.lines.filter { $0.contains("not a complete PDF") }.count == 3)
    await rig.pickup.pickUpOnce()
    await rig.pickup.pickUpOnce()
    #expect(rig.logs.lines.filter { $0.contains("not a complete PDF") }.count == 3)
    #expect(rig.files.isEmpty)
}

@Test func aScanListedWithoutBytesIsSkippedWithOneLogLine() async throws {
    let rig = Rig()
    let transport = FakeBinaryTransport { r in
        if r.path == "/health" { return (200, Data(#"{"buttonScans":true}"#.utf8)) }
        return (200, Data(#"{"scans":[{"id":"\#(idA)","name":"a.pdf","pages":1,"ocr":"done"}]}"#.utf8))
    }
    let logs = rig.logs
    let pickup = ButtonScanPickup(store: rig.store, folder: rig.folder, ledger: rig.ledger, transport: { _ in transport },
                                  log: { logs.add($0) })
    await pickup.pickUpOnce()
    await pickup.pickUpOnce()
    #expect(!transport.sent.contains { $0.path.hasPrefix("/button-scans/") })
    #expect(logs.lines.filter { $0.contains("without a size") }.count == 1)
}

@Test func aDownload404MeansGoneWithoutLogOrError() async {
    let rig = Rig()
    let ids = ["c", "d", "e", "f"].map { String(repeating: $0, count: 22) }
    for id in ids { rig.script.add(id, name: "\(id.prefix(1)).pdf") }
    rig.script.goneIds = Set(ids.prefix(3))
    await rig.pickup.pickUpOnce()
    #expect(rig.files == ["f.pdf"])      // three 404s did not end the server's turn
    #expect(rig.logs.lines.allSatisfy { !$0.contains("status 404") && !$0.contains("will retry") })
}

@Test func theHandlerCanBeSetAfterInit() async {
    let rig = Rig()
    let late = Rig.Box()
    rig.pickup.onPickedUp = { late.add($0) }
    rig.script.add(idA, name: "scan_2026-11-10_151030.pdf")
    await rig.pickup.pickUpOnce()
    #expect(late.scans.count == 1)
    #expect(rig.picked.scans.isEmpty)
}
