import Foundation
import Testing
@testable import HelperCore

private struct EchoEngine: OcrEngine {
    var fail: String? = nil
    func makeSearchable(_ input: OcrJobInput) async throws -> Data {
        if let fail { throw ProtocolError(500, fail) }
        return Data("PDF \(input.pages.count) \(input.languages.joined(separator: "+"))".utf8)
    }
}

/// Holds every job until `release()`.
private final class GateEngine: OcrEngine, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private var open = false
    func release() { lock.lock(); open = true; let c = continuation; continuation = nil; lock.unlock(); c?.resume() }
    func makeSearchable(_ input: OcrJobInput) async throws -> Data {
        await withCheckedContinuation { c in
            lock.lock(); if open { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
        }
        return Data("ok".utf8)
    }
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ocr-jobs-test-\(UUID().uuidString)")
}
private let page = PageImage(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), dpi: 300)

@Test func idsAreUrlSafeAndLong() async throws {
    let queue = OcrJobQueue(root: tempRoot(), engine: EchoEngine())
    await queue.start()
    let id = try await queue.submit(pages: [page], name: "a.pdf", languages: [], fakeTexts: nil)
    #expect(OcrJobQueue.isValidID(id))
    #expect(id.count >= 22)
    #expect(!OcrJobQueue.isValidID("../etc") && !OcrJobQueue.isValidID("short"))
}

@Test func doneIsFetchedOnce() async throws {
    let queue = OcrJobQueue(root: tempRoot(), engine: EchoEngine())
    await queue.start()
    let id = try await queue.submit(pages: [page, page], name: "a.pdf", languages: ["eng"], fakeTexts: nil)
    await queue.waitUntilIdle()
    #expect(await queue.fetch(id) == .done(name: "a.pdf", pages: 2, pdf: Data("PDF 2 eng".utf8)))
    #expect(await queue.fetch(id) == .unknown)
    #expect(await queue.fetch("no-such-job-0000000000000") == .unknown)
}

@Test func failureIsFinal() async throws {
    let queue = OcrJobQueue(root: tempRoot(), engine: EchoEngine(fail: "No page could be read."))
    await queue.start()
    let id = try await queue.submit(pages: [page], name: "a.pdf", languages: [], fakeTexts: nil)
    await queue.waitUntilIdle()
    #expect(await queue.fetch(id) == .failed("No page could be read."))
    #expect(await queue.fetch(id) == .unknown)
}

@Test func positionsCountJobsAhead() async throws {
    let engine = GateEngine()
    let queue = OcrJobQueue(root: tempRoot(), engine: engine)
    await queue.start()
    let a = try await queue.submit(pages: [page], name: "a.pdf", languages: [], fakeTexts: nil)
    let b = try await queue.submit(pages: [page], name: "b.pdf", languages: [], fakeTexts: nil)
    let c = try await queue.submit(pages: [page], name: "c.pdf", languages: [], fakeTexts: nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(await queue.fetch(a) == .pending(state: "running", position: 0))
    #expect(await queue.fetch(b) == .pending(state: "queued", position: 1))
    #expect(await queue.fetch(c) == .pending(state: "queued", position: 2))
    engine.release()
    await queue.waitUntilIdle()
    #expect(await queue.fetch(c) == .done(name: "c.pdf", pages: 1, pdf: Data("ok".utf8)))
}

@Test func unfinishedJobsResumeAfterRestartInOrder() async throws {
    let root = tempRoot()
    let first = OcrJobQueue(root: root, engine: GateEngine())  // never released: jobs stay unfinished
    await first.start()
    let a = try await first.submit(pages: [page], name: "a.pdf", languages: [], fakeTexts: nil)
    let b = try await first.submit(pages: [page], name: "b.pdf", languages: [], fakeTexts: nil)
    let second = OcrJobQueue(root: root, engine: GateEngine())
    await second.start()
    let statusA = await second.fetch(a)
    #expect(statusA == .pending(state: "queued", position: 0) || statusA == .pending(state: "running", position: 0))
    #expect(await second.fetch(b) == .pending(state: "queued", position: 1))
    let third = OcrJobQueue(root: root, engine: EchoEngine())
    await third.start()
    await third.waitUntilIdle()
    #expect(await third.fetch(b) == .done(name: "b.pdf", pages: 1, pdf: Data("PDF 1 ".utf8)))
}

@Test func expiredJobsAreGone() async throws {
    let root = tempRoot()
    let clock = Clock()
    let queue = OcrJobQueue(root: root, engine: EchoEngine(), now: { clock.now })
    await queue.start()
    let id = try await queue.submit(pages: [page], name: "a.pdf", languages: [], fakeTexts: nil)
    await queue.waitUntilIdle()
    clock.now = clock.now.addingTimeInterval(OcrJobQueue.retention + 1)
    #expect(await queue.fetch(id) == .unknown)
    let restarted = OcrJobQueue(root: root, engine: EchoEngine(), now: { clock.now })
    await restarted.start()
    #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true)
}

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 2_000_000_000) }
