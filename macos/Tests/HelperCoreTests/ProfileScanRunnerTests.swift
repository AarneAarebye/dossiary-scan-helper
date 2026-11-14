import Foundation
import Testing
@testable import HelperCore

private func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-runner-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct Rig {
    let folder = tempFolder()
    let runner: ProfileScanRunner
    let router: Router

    init(withOcr: Bool = false, giveUp: Double = 0.2, ocrDelay: Double = 2) async {
        var jobs: OcrJobQueue?
        if withOcr {
            jobs = OcrJobQueue(root: tempFolder(), engine: FakeOcrEngine(delay: ocrDelay), log: { _ in })
            await jobs?.start()
        }
        router = Router(backend: FakeBackend(), pairing: PairingStore(mode: .fake), ocrJobs: jobs)
        let writer = ButtonScanFolder(defaults: UserDefaults(suiteName: "profile-runner-\(UUID().uuidString)")!,
                                      fallback: tempFolder())
        runner = ProfileScanRunner(router: router, writer: writer, ocrPollSeconds: 0.01, ocrGiveUpSeconds: giveUp)
    }

    func profile(_ scannerID: String, name: String = "Fake", format: String = "pdf", ocr: Bool = false) -> ScanProfile {
        ScanProfile(name: "p", scannerID: scannerID, scannerName: name, destination: folder.path, source: .flatbed,
                    colorMode: .color, resolution: 300, format: format, ocr: ocr, ocrLanguages: ocr ? ["eng"] : [])
    }

    func cleanup() { try? FileManager.default.removeItem(at: folder) }
}

@Test func aProfileScanSavesAPdfInTheProfilesFolder() async throws {
    let rig = await Rig()
    defer { rig.cleanup() }
    let outcome = await rig.runner.run(rig.profile("fake:flatbed"))
    guard case .saved(let files, let pages, let searchable) = outcome else { Issue.record("\(outcome)"); return }
    #expect(pages == 1 && searchable == nil && files.count == 1)
    #expect(files[0].deletingLastPathComponent().standardizedFileURL == rig.folder.standardizedFileURL)
    #expect(files[0].lastPathComponent.hasPrefix("scan_") && files[0].pathExtension == "pdf")
    #expect(try Data(contentsOf: files[0]).starts(with: Data("%PDF".utf8)))
}

@Test func anImageProfileSavesAJpeg() async throws {
    let rig = await Rig()
    defer { rig.cleanup() }
    let outcome = await rig.runner.run(rig.profile("fake:photo", name: "Fake Photo Scanner", format: "jpeg"))
    guard case .saved(let files, _, _) = outcome else { Issue.record("\(outcome)"); return }
    #expect(files[0].pathExtension == "jpg")
}

@Test func twoScansNeverOverwriteEachOther() async throws {
    let rig = await Rig()
    defer { rig.cleanup() }
    var names = Set<String>()
    for _ in 0..<2 {
        if case .saved(let files, _, _) = await rig.runner.run(rig.profile("fake:flatbed")) { names.formUnion(files.map(\.lastPathComponent)) }
    }
    #expect(names.count == 2)
}

@Test func searchableTextIsWaitedForAndSaved() async throws {
    let rig = await Rig(withOcr: true, giveUp: 5)
    defer { rig.cleanup() }
    let outcome = await rig.runner.run(rig.profile("fake:ocr", name: "Fake OCR Scanner", ocr: true))
    guard case .saved(_, _, let searchable) = outcome else { Issue.record("\(outcome)"); return }
    #expect(searchable == true)
}

@Test func aMissingScannerFails() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    let outcome = await rig.runner.run(rig.profile("remote:gone:x", name: "Canon CanoScan 8800F (node-000)"))
    #expect(outcome == .problem(.scannerMissing("Canon CanoScan 8800F (node-000)")))
}

@Test func anOfflineScannerFailsWithTheReason() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    let outcome = await rig.runner.run(rig.profile("fake:offline", name: "Fake Offline Scanner"))
    guard case .failed(let message) = outcome else { Issue.record("\(outcome)"); return }
    #expect(!message.isEmpty)
}

@Test func aJamKeepsThePagesThatCameBack() async throws {
    let rig = await Rig()
    defer { rig.cleanup() }
    var profile = rig.profile("fake:jam", name: "Fake Jamming Feeder")
    profile.source = .feeder
    let outcome = await rig.runner.run(profile)
    guard case .partial(let files, let message) = outcome else { Issue.record("\(outcome)"); return }
    #expect(files.count == 1 && message?.isEmpty == false)
}

@Test func textRecognitionThatNeverFinishesIsGivenUpOnAndThePlainScanIsKept() async throws {
    let rig = await Rig(withOcr: true, giveUp: 0.05, ocrDelay: 60)
    defer { rig.cleanup() }
    let outcome = await rig.runner.run(rig.profile("fake:ocr", name: "Fake OCR Scanner", ocr: true))
    guard case .saved(let files, _, let searchable) = outcome else { Issue.record("\(outcome)"); return }
    #expect(searchable == false && files.count == 1)
}

@Test func onlyOneProfileScanRunsAtATime() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    let slow = rig.profile("fake:slow", name: "Fake Slow Scanner")
    async let first = rig.runner.run(slow)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(rig.runner.isRunning)
    let second = await rig.runner.run(slow)
    #expect(second == .problem(.busy))
    _ = await first
    #expect(!rig.runner.isRunning)
}

@Test func theRunnerReportsStartAndEnd() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    let calls = Counter()
    rig.runner.onChange = { calls.bump() }
    _ = await rig.runner.run(rig.profile("fake:flatbed"))
    #expect(calls.value == 2)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[URL]] = []
    func add(_ files: [URL]) { lock.withLock { calls.append(files) } }
    var all: [[URL]] { lock.withLock { calls } }
}

@Test func withTheSwitchOnTheSavedFilesAreHandedOver() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    var p = rig.profile("fake:flatbed"); p.sendToDossiary = true
    let got = Received()
    let result = await rig.runner.runAndHandOver(p) { files in got.add(files); return .sent }
    guard case .saved(let files, _, _) = result.outcome else { Issue.record("\(result.outcome)"); return }
    #expect(got.all == [files] && result.handOver == .sent)
}

@Test func withTheSwitchOffNothingIsHandedOver() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    let got = Received()
    let result = await rig.runner.runAndHandOver(rig.profile("fake:flatbed")) { files in got.add(files); return .sent }
    #expect(got.all.isEmpty && result.handOver == nil)
    guard case .saved = result.outcome else { Issue.record("\(result.outcome)"); return }
}

@Test func aFailedScanIsNeverHandedOver() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    var failing = rig.profile("fake:offline", name: "Fake Offline Scanner"); failing.sendToDossiary = true
    var missing = rig.profile("remote:gone:x", name: "Gone"); missing.sendToDossiary = true
    let got = Received()
    for p in [failing, missing] {
        let result = await rig.runner.runAndHandOver(p) { files in got.add(files); return .sent }
        #expect(result.handOver == nil)
    }
    #expect(got.all.isEmpty)
}

@Test func aPartialScanHandsOverOnlyTheSavedFiles() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    var p = rig.profile("fake:jam", name: "Fake Jamming Feeder"); p.source = .feeder; p.sendToDossiary = true
    let got = Received()
    let result = await rig.runner.runAndHandOver(p) { files in got.add(files); return .sent }
    guard case .partial(let files, _) = result.outcome else { Issue.record("\(result.outcome)"); return }
    #expect(got.all == [files] && result.handOver == .sent)
}

@Test func notInstalledAndFailedArePassedThroughAndTheScanStaysSaved() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    var p = rig.profile("fake:flatbed"); p.sendToDossiary = true
    let a = await rig.runner.runAndHandOver(p) { _ in .notInstalled }
    #expect(a.handOver == .notInstalled)
    guard case .saved = a.outcome else { Issue.record("\(a.outcome)"); return }
    let b = await rig.runner.runAndHandOver(p) { _ in .failed("x") }
    #expect(b.handOver == .failed("x"))
    guard case .saved = b.outcome else { Issue.record("\(b.outcome)"); return }
}

@Test func severalFilesAreHandedOverInOneCall() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    var p = rig.profile("fake:splitter", name: "Fake Splitter"); p.source = .feeder; p.sendToDossiary = true
    let got = Received()
    let result = await rig.runner.runAndHandOver(p) { files in got.add(files); return .sent }
    guard case .saved(let files, _, _) = result.outcome else { Issue.record("\(result.outcome)"); return }
    #expect(got.all.count == 1 && got.all[0] == files)
}
