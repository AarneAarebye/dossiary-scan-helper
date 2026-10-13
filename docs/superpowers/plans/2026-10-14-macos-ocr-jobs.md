# macOS helper: background OCR jobs with Vision — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS helper offers `ocr` on every scanner, answers a scan with `ocr: true` at once with an `ocrJob` per file, makes each file searchable in the background with Apple's Vision framework, and delivers it through `GET /ocr/<job>`; its fake mode gains `fake:ocr`, so the conformance suite's OCR tests run against it.

**Architecture:** Step 4 of `/Users/aarneaarebye/Projects/Paperless/Dossiary/docs/superpowers/specs/2026-10-11-background-scan-ocr-design.md` (read section 2 and "macOS helper" in section 3); the wire format is `PROTOCOL.md` "Background OCR" and the `fake:ocr` rows of "Fake scanner mode". A disk-backed actor queue (`OcrJobQueue`) runs one job at a time through an `OcrEngine`: `VisionOcrEngine` for real scanners (`VNRecognizeTextRequest`, accurate; the recognized lines go into a CoreGraphics PDF as invisible CoreText text over the unchanged page image), `FakeOcrEngine` for `fake:ocr` (2 s, then a hand-written PDF whose bytes contain the literal page text, which the conformance suite searches for). The engine runs off the actor, so `GET /ocr/<job>` answers while a job runs.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, Command Line Tools only (no Xcode), Foundation, CoreGraphics, CoreText, ImageIO, Vision, PDFKit (tests), Swift Testing.

## Global Constraints

- Repo: `/Users/aarneaarebye/Projects/Paperless/dossiary-scan-helper`, package in `macos/`. Work on a branch in a worktree under `.worktrees/` (git-ignored).
- **Unit tests:** `cd macos && scripts/test.sh` (created in Task 1; it is `swift test` plus the Command Line Tools' Swift Testing macro plugin path, which a recent Command Line Tools update moved into `usr/lib/swift/host/plugins/testing/` where SwiftPM no longer finds it on its own). Plain `swift test` fails with "plugin for module 'TestingMacros' not found" on this Mac. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`); XCTest isn't available.
- **Conformance:** `cd macos && PORT=8797 scripts/run-conformance.sh`. Never bind 8765 or 8766 (the owner's live helpers run there). Baseline before this plan: 43 tests OK, 1 skipped (the OCR class, because `fake:ocr` isn't listed). After Task 4: the OCR class runs and passes, nothing skipped.
- Build floor macOS 14; no new package dependencies; only system frameworks.
- Protocol values, exactly (PROTOCOL.md):
  - Scanner entry gains `"ocr": {"languages": [...]}` only when the helper can make a searchable PDF for it. Codes: `deu`, `eng`, `fra`, `spa`, `chi_sim`, `chi_tra`.
  - `POST /scan` fields `ocr` (boolean) and `ocrLanguages` (array of strings, most likely first; missing or `[]` = helper's choice; a repeated code counts once). Type errors → 400 at validation step 4 (with the other type checks, before any 422); `ocr: true` for a scanner without `ocr`, or an `ocrLanguages` entry not in its list → 422 at step 5. `ocrLanguages` without `ocr: true` is type-checked only.
  - With `ocr: true` every file gains `ocrJob`: random, ≥ 128 bits, URL-safe (`A-Z a-z 0-9 - _`), ≥ 22 characters. The file is the plain scan.
  - `GET /ocr/<job>`: token required (401); `202 {"ok": true, "state": "queued"|"running", "position": n}` (`position` = jobs ahead, 0 while running); `200 {"ok": true, "files": [{"name", "pages", "data"}]}` — exactly one file, same `name` and `pages` as the plain file; `404` unknown/fetched/expired; `500` error body when OCR failed, final (the job is gone afterwards). Fetching a 200 or a 500 deletes the job. Other methods → 405 with `Allow: GET, OPTIONS`. `/ocr` and `/ocr/` → 404. CORS as for every endpoint.
  - Jobs run one at a time; a new scan may start while jobs run (only a second simultaneous scan gets 409).
  - Retention 7 days after the scan; real jobs live on disk in `~/Library/Application Support/dossiary-scan-helper/ocr-jobs/<id>/` and survive restarts (unfinished ones resume in original order).
  - A page whose text can't be recognized is left without text and the job still answers 200; 500 only when no searchable PDF could be made at all.
  - `fake:ocr`: name `Fake OCR Scanner`, sources `["flatbed"]`, duplex false, colour modes and resolutions as every fake, extras `[]`, `ocr.languages` `["deu", "eng"]`. Without `ocr: true`: one page `Flatbed page 1`, no `ocrJob`, and the PDF's bytes contain the literal text `Flatbed page 1`. With `ocr: true`: the plain PDF's bytes do *not* contain it; its job answers 202 for 2 seconds after the scan, then 200 with a one-page PDF whose bytes contain `Flatbed page 1`.
- Vision language codes: `deu`→`de-DE`, `eng`→`en-US`, `fra`→`fr-FR`, `spa`→`es-ES`, `chi_sim`→`zh-Hans`, `chi_tra`→`zh-Hant`. A real scanner offers the codes whose Vision language `VNRecognizeTextRequest.supportedRecognitionLanguages()` lists (all six on current macOS). The helper's choice when none are requested: `deu`, `eng`.
- No straightening (no deskew). The page image is drawn unchanged.
- Never log tokens, pairing codes or page data; log job ids only by their first 6 characters.
- `HelperVersion.string` becomes `0.2.0`.
- Messages are plain English for a person; error bodies are `Router.errorBody(...)`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo
  ```

---

### Task 1: Protocol fields — scanner `ocr`, request validation, test script

**Files:**
- Create: `macos/scripts/test.sh`
- Modify: `macos/Sources/HelperCore/Model.swift`
- Modify: `macos/Sources/HelperCore/ScanRequestValidator.swift`
- Create: `macos/Sources/HelperCore/OcrLanguages.swift`
- Test: `macos/Tests/HelperCoreTests/ValidationTests.swift` (add), `macos/Tests/HelperCoreTests/OcrLanguagesTests.swift` (new)
- Modify: `macos/README.md` (test command)

**Interfaces:**
- Produces: `ScannerInfo.ocrLanguages: [String]` (empty = no OCR; `json` adds `"ocr": {"languages": ...}` only when non-empty; `init` gains a trailing `ocrLanguages: [String] = []`). `ScanSettings.ocr: Bool`, `ScanSettings.ocrLanguages: [String]` (deduplicated, request order; `init` gains trailing `ocr: Bool = false, ocrLanguages: [String] = []`). `OcrLanguages.all`, `OcrLanguages.visionLanguage(for:)`, `OcrLanguages.defaultCodes`, `OcrLanguages.offered(supportedVision:)`, `OcrLanguages.visionLanguages(for:)`.

- [ ] **Step 1: Test script**

`macos/scripts/test.sh`:

```bash
#!/bin/bash
# Runs the unit tests. Newer Command Line Tools keep the Swift Testing macro plugin in
# usr/lib/swift/host/plugins/testing/, where SwiftPM doesn't look; pass that folder when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
```

`chmod +x macos/scripts/test.sh`. Run `macos/scripts/test.sh` → 64 tests pass. In `macos/README.md` "Build and test", replace `swift test                      # unit tests` with `scripts/test.sh                 # unit tests (swift test, plus the Testing plugin path)`.

- [ ] **Step 2: Failing tests**

`macos/Tests/HelperCoreTests/OcrLanguagesTests.swift`:

```swift
import Testing
@testable import HelperCore

@Test func visionLanguageMapping() {
    #expect(OcrLanguages.visionLanguage(for: "deu") == "de-DE")
    #expect(OcrLanguages.visionLanguage(for: "chi_tra") == "zh-Hant")
    #expect(OcrLanguages.visionLanguage(for: "xyz") == nil)
}

@Test func offeredFollowsVisionSupport() {
    #expect(OcrLanguages.offered(supportedVision: ["en-US", "de-DE", "ja-JP"]) == ["deu", "eng"])
    #expect(OcrLanguages.offered(supportedVision: []) == [])
    #expect(OcrLanguages.offered(supportedVision: OcrLanguages.all.map(\.vision)) ==
            ["deu", "eng", "fra", "spa", "chi_sim", "chi_tra"])
}

@Test func visionLanguagesKeepOrderAndDefault() {
    #expect(OcrLanguages.visionLanguages(for: ["eng", "deu"]) == ["en-US", "de-DE"])
    #expect(OcrLanguages.visionLanguages(for: []) == ["de-DE", "en-US"])
}

@Test func scannerJsonHasOcrOnlyWhenOffered() {
    var info = ScannerInfo(id: "x", name: "X", sources: [.flatbed], duplex: false, colorModes: [.color],
                           resolutions: [300], extras: [])
    #expect(info.json["ocr"] == nil)
    info.ocrLanguages = ["deu", "eng"]
    #expect((info.json["ocr"] as? [String: Any])?["languages"] as? [String] == ["deu", "eng"])
}
```

Add to `ValidationTests.swift` (reuse that file's existing helpers if it has a scanner fixture; otherwise these local ones):

```swift
private let ocrScanner = ScannerInfo(id: "s:ocr", name: "OCR Scanner", sources: [.flatbed], duplex: false,
                                     colorModes: [.color], resolutions: [300], extras: [], ocrLanguages: ["deu", "eng"])
private let plainScanner = ScannerInfo(id: "s:plain", name: "Plain Scanner", sources: [.flatbed], duplex: false,
                                       colorModes: [.color], resolutions: [300], extras: [])

private func ocrStatus(_ body: [String: Any]) -> Int? {
    do { _ = try ScanRequestValidator.validate(body, scanners: [ocrScanner, plainScanner]); return nil }
    catch let error as ProtocolError { return error.status } catch { return -1 }
}

@Test func ocrFieldTypes() {
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": "yes"]) == 400)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": 1]) == 400)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": true, "ocrLanguages": "deu"]) == 400)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": true, "ocrLanguages": [1]]) == 400)
    // Type errors come before 422s.
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": "yes", "ocrLanguages": ["xyz"]]) == 400)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": true, "resolution": 301, "ocrLanguages": [1]]) == 400)
}

@Test func ocrValues() throws {
    #expect(ocrStatus(["scanner": "s:plain", "ocr": true]) == 422)
    #expect(ocrStatus(["scanner": "s:ocr", "ocr": true, "ocrLanguages": ["xyz"]]) == 422)
    #expect(ocrStatus(["scanner": "s:plain", "ocr": false]) == nil)
    #expect(ocrStatus(["scanner": "s:plain", "ocrLanguages": ["xyz"]]) == nil)  // type-checked only
    let (_, settings) = try ScanRequestValidator.validate(
        ["scanner": "s:ocr", "ocr": true, "ocrLanguages": ["eng", "deu", "eng"]], scanners: [ocrScanner])
    #expect(settings.ocr)
    #expect(settings.ocrLanguages == ["eng", "deu"])
    let (_, plain) = try ScanRequestValidator.validate(["scanner": "s:ocr"], scanners: [ocrScanner])
    #expect(!plain.ocr && plain.ocrLanguages.isEmpty)
}
```

Run `scripts/test.sh` → fails to compile (`ocrLanguages`, `OcrLanguages` unknown).

- [ ] **Step 3: Implement**

`Model.swift` — `ScannerInfo`: add `public var ocrLanguages: [String]`, the init parameter `ocrLanguages: [String] = []` (last), and in `json`:

```swift
    public var json: [String: Any] {
        var object: [String: Any] = ["id": id, "name": name, "sources": sources.map(\.rawValue), "duplex": duplex,
                                     "colorModes": colorModes.map(\.rawValue), "resolutions": resolutions, "extras": extras]
        if !ocrLanguages.isEmpty { object["ocr"] = ["languages": ocrLanguages] }
        return object
    }
```

`ScanSettings`: add `public var ocr: Bool` and `public var ocrLanguages: [String]`, init parameters `ocr: Bool = false, ocrLanguages: [String] = []` (last).

`OcrLanguages.swift`:

```swift
import Foundation

/// The protocol's Tesseract-style OCR codes and the Vision languages they stand for.
public enum OcrLanguages {
    public static let all: [(code: String, vision: String)] = [
        ("deu", "de-DE"), ("eng", "en-US"), ("fra", "fr-FR"), ("spa", "es-ES"),
        ("chi_sim", "zh-Hans"), ("chi_tra", "zh-Hant"),
    ]
    /// The helper's choice when a request names no languages.
    public static let defaultCodes = ["deu", "eng"]

    public static func visionLanguage(for code: String) -> String? { all.first { $0.code == code }?.vision }

    /// The codes a real scanner offers: those whose Vision language this Mac supports, in `all` order.
    public static func offered(supportedVision: [String]) -> [String] {
        all.filter { supportedVision.contains($0.vision) }.map(\.code)
    }

    /// Vision languages for a request's codes, in request order; the default codes when none are given.
    public static func visionLanguages(for codes: [String]) -> [String] {
        (codes.isEmpty ? defaultCodes : codes).compactMap(visionLanguage(for:))
    }
}
```

`ScanRequestValidator.validate` — after the `extras` type loop (still inside step 4):

```swift
        if object["ocr"] != nil && JSONBody.bool(object["ocr"]) == nil {
            throw ProtocolError(400, "“ocr” must be true or false.")
        }
        var ocrLanguages: [String] = []
        if let raw = object["ocrLanguages"] {
            guard let list = raw as? [Any], list.allSatisfy({ $0 is String }) else {
                throw ProtocolError(400, "“ocrLanguages” must be a list of language codes.")
            }
            for case let code as String in list where !ocrLanguages.contains(code) { ocrLanguages.append(code) }
        }
```

and after the extras 422 loop (end of step 5):

```swift
        let ocr = JSONBody.bool(object["ocr"]) ?? false
        if ocr {
            guard !scanner.ocrLanguages.isEmpty else {
                throw ProtocolError(422, "\(scanner.name) can't make searchable PDFs.")
            }
            for code in ocrLanguages where !scanner.ocrLanguages.contains(code) {
                throw ProtocolError(422, "\(scanner.name) can't recognize text in “\(code)”.")
            }
        }
```

and pass `ocr: ocr, ocrLanguages: ocr ? ocrLanguages : []` to the returned `ScanSettings`. (A JSON number is an `NSNumber`, never `String`, so `[1]` fails the `is String` check.)

- [ ] **Step 4: Run** `scripts/test.sh` → all pass (64 + the new ones). `PORT=8797 scripts/run-conformance.sh` → 43 OK, 1 skipped.

- [ ] **Step 5: Commit** — `git add macos && git commit -m "macOS helper: ocr scanner field and ocr/ocrLanguages validation; test script finds the Testing plugin"` (with the trailer).

---

### Task 2: `OcrJobQueue` — disk-backed, one job at a time

**Files:**
- Create: `macos/Sources/HelperCore/OcrJobQueue.swift`
- Test: `macos/Tests/HelperCoreTests/OcrJobQueueTests.swift`

**Interfaces:**
- Consumes: `PageImage` (`ScannerBackend.swift`), `ProtocolError`.
- Produces:
  ```swift
  public struct OcrJobInput: Sendable { pages: [PageImage]; languages: [String]; fakeTexts: [String]?; createdAt: Date }
  public protocol OcrEngine: Sendable { func makeSearchable(_ input: OcrJobInput) async throws -> Data }
  public enum OcrJobStatus: Equatable, Sendable {
      case pending(state: String, position: Int); case done(name: String, pages: Int, pdf: Data)
      case failed(String); case unknown }
  public actor OcrJobQueue {
      public static let retention: TimeInterval            // 7 days
      public static var defaultRoot: URL                     // ~/Library/Application Support/dossiary-scan-helper/ocr-jobs
      public static func isValidID(_ id: String) -> Bool
      public init(root: URL, engine: OcrEngine, now: @escaping @Sendable () -> Date = { Date() },
                  log: @escaping @Sendable (String) -> Void = { _ in })
      public func start()                                    // load from disk, expire, resume
      public func submit(pages: [PageImage], name: String, languages: [String], fakeTexts: [String]?) throws -> String
      public func fetch(_ id: String) -> OcrJobStatus        // .done and .failed delete the job
      public func waitUntilIdle() async                      // tests only
  }
  ```
  An engine error's message: a `ProtocolError`'s `message`, otherwise `"Text recognition failed: <localizedDescription>"`.

- [ ] **Step 1: Failing tests**

`OcrJobQueueTests.swift`:

```swift
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
    #expect(await second.fetch(a) == .pending(state: "queued", position: 0) ||
            await second.fetch(a) == .pending(state: "running", position: 0))
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
```

Run `scripts/test.sh --filter OcrJobQueueTests` → fails to compile.

- [ ] **Step 2: Implement** `OcrJobQueue.swift`:

```swift
import Foundation
import Security

public struct OcrJobInput: Sendable {
    public let pages: [PageImage]
    public let languages: [String]
    /// fake:ocr only: the text of each page, which FakeOcrEngine writes into the result.
    public let fakeTexts: [String]?
    public let createdAt: Date
}

/// Makes one searchable PDF. Throws when no searchable PDF could be made at all (the job then answers 500).
public protocol OcrEngine: Sendable {
    func makeSearchable(_ input: OcrJobInput) async throws -> Data
}

public enum OcrJobStatus: Equatable, Sendable {
    case pending(state: String, position: Int)
    case done(name: String, pages: Int, pdf: Data)
    case failed(String)
    case unknown
}

/// PROTOCOL.md "Background OCR": jobs run one at a time, live on disk until fetched (at most 7 days), and
/// resume after a restart. Layout: <root>/<id>/meta.json, page-<n>.img, result.pdf.
public actor OcrJobQueue {
    public static let retention: TimeInterval = 7 * 24 * 3600
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dossiary-scan-helper/ocr-jobs")
    }

    struct Meta: Codable {
        var name: String
        var pages: Int
        var dpis: [Int]
        var languages: [String]
        var fakeTexts: [String]?
        var createdAt: Date
        var sequence: Int
        var state: String       // "queued", "done", "failed"
        var message: String?
    }

    private let root: URL
    private let engine: OcrEngine
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var order: [String] = []   // unfinished jobs, oldest first; order[0] runs
    private var running: String?
    private var nextSequence = 0
    private var worker: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(root: URL, engine: OcrEngine, now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.root = root; self.engine = engine; self.now = now; self.log = log
    }

    public static func isValidID(_ id: String) -> Bool {
        id.count >= 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func readMeta(_ id: String) -> Meta? {
        guard let data = try? Data(contentsOf: dir(id).appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func writeMeta(_ meta: Meta, _ id: String) throws {
        try JSONEncoder().encode(meta).write(to: dir(id).appendingPathComponent("meta.json"), options: .atomic)
    }

    private func remove(_ id: String) { try? FileManager.default.removeItem(at: dir(id)) }

    private func expired(_ meta: Meta) -> Bool { now().timeIntervalSince(meta.createdAt) > OcrJobQueue.retention }

    /// Loads jobs left from an earlier run: drops expired ones and resumes unfinished ones in their order.
    public func start() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var unfinished: [(Int, String)] = []
        for id in names where OcrJobQueue.isValidID(id) {
            guard let meta = readMeta(id), !expired(meta) else { remove(id); continue }
            nextSequence = max(nextSequence, meta.sequence + 1)
            if meta.state == "queued" { unfinished.append((meta.sequence, id)) }
        }
        order = unfinished.sorted { $0.0 < $1.0 }.map(\.1)
        if !order.isEmpty { log("Resuming \(order.count) text recognition job(s).") }
        kick()
    }

    public func submit(pages: [PageImage], name: String, languages: [String], fakeTexts: [String]?) throws -> String {
        let id = OcrJobQueue.newID()
        let folder = dir(id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, page) in pages.enumerated() {
                try page.data.write(to: folder.appendingPathComponent("page-\(index + 1).img"))
            }
            let meta = Meta(name: name, pages: pages.count, dpis: pages.map(\.dpi), languages: languages,
                            fakeTexts: fakeTexts, createdAt: now(), sequence: nextSequence, state: "queued", message: nil)
            try writeMeta(meta, id)
        } catch {
            remove(id)
            throw error
        }
        nextSequence += 1
        order.append(id)
        log("Text recognition job \(id.prefix(6))… queued for \(name).")
        kick()
        return id
    }

    public func fetch(_ id: String) -> OcrJobStatus {
        guard OcrJobQueue.isValidID(id), let meta = readMeta(id) else { return .unknown }
        if expired(meta) {
            order.removeAll { $0 == id && $0 != running }
            if running != id { remove(id) }
            return .unknown
        }
        switch meta.state {
        case "done":
            guard let pdf = try? Data(contentsOf: dir(id).appendingPathComponent("result.pdf")) else {
                remove(id); return .failed("The searchable PDF went missing.")
            }
            remove(id)
            return .done(name: meta.name, pages: meta.pages, pdf: pdf)
        case "failed":
            remove(id)
            return .failed(meta.message ?? "Text recognition failed.")
        default:
            let position = order.firstIndex(of: id) ?? 0
            return .pending(state: id == running ? "running" : "queued", position: position)
        }
    }

    /// Tests only: returns once no job is queued or running.
    public func waitUntilIdle() async {
        if worker == nil && order.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func kick() {
        guard worker == nil, !order.isEmpty else { return }
        worker = Task { await self.runAll() }
    }

    private func runAll() async {
        while let id = order.first {
            running = id
            await runOne(id)
            running = nil
            if order.first == id { order.removeFirst() }
            expireFinished()
        }
        worker = nil
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func runOne(_ id: String) async {
        guard var meta = readMeta(id) else { return }
        let folder = dir(id)
        var pages: [PageImage] = []
        for index in 0..<meta.pages {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("page-\(index + 1).img")) else {
                meta.state = "failed"; meta.message = "A scanned page of this job went missing."
                try? writeMeta(meta, id); return
            }
            pages.append(PageImage(data: data, dpi: meta.dpis[index]))
        }
        let input = OcrJobInput(pages: pages, languages: meta.languages, fakeTexts: meta.fakeTexts,
                                createdAt: meta.createdAt)
        let engine = self.engine
        do {
            // Off the actor, so fetch() keeps answering while the engine works.
            let pdf = try await Task.detached(priority: .utility) { try await engine.makeSearchable(input) }.value
            try pdf.write(to: folder.appendingPathComponent("result.pdf"), options: .atomic)
            meta.state = "done"
            log("Text recognition job \(id.prefix(6))… done.")
        } catch {
            meta.state = "failed"
            meta.message = (error as? ProtocolError)?.message ?? "Text recognition failed: \(error.localizedDescription)"
            log("Text recognition job \(id.prefix(6))… failed: \(meta.message ?? "")")
        }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }  // expired meanwhile
        try? writeMeta(meta, id)
        for index in 0..<meta.pages {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("page-\(index + 1).img"))
        }
    }

    private func expireFinished() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for id in names where OcrJobQueue.isValidID(id) && id != running {
            if let meta = readMeta(id), expired(meta) { order.removeAll { $0 == id }; remove(id) }
        }
    }
}
```

If the `unfinishedJobsResumeAfterRestartInOrder` test's `||` expression fails to type-check inside `#expect` (two awaits), split it: `let s = await second.fetch(a); #expect(s == .pending(state: "queued", position: 0) || s == .pending(state: "running", position: 0))`. Note the test shares one `root` between three queue instances; the first two never finish (their `GateEngine`s are never released) — that's expected, they're simply abandoned.

- [ ] **Step 3: Run** `scripts/test.sh` → all pass.
- [ ] **Step 4: Commit** — `"macOS helper: disk-backed OCR job queue"` (with trailer).

---

### Task 3: Engines — Vision OCR, searchable PDF, fake:ocr

**Files:**
- Create: `macos/Sources/HelperCore/VisionOcrEngine.swift`
- Create: `macos/Sources/HelperCore/RawPdf.swift`
- Create: `macos/Sources/HelperCore/FakeOcrEngine.swift`
- Modify: `macos/Sources/HelperCore/PdfBuilder.swift`
- Modify: `macos/Sources/HelperCore/ScannerBackend.swift` (`ScanDocuments` gains `pdfs` and `fakeTexts`)
- Modify: `macos/Sources/HelperCore/FakeScanners.swift`, `macos/Sources/HelperCore/FakeBackend.swift`
- Test: `macos/Tests/HelperCoreTests/OcrEngineTests.swift` (new), `macos/Tests/HelperCoreTests/FakeScanTests.swift` (add), `macos/Tests/HelperCoreTests/RouterTests.swift` (fake count 7 → 8)

**Interfaces:**
- Consumes: `OcrEngine`, `OcrJobInput` (Task 2); `OcrLanguages` (Task 1).
- Produces:
  - `public struct OcrLine: Sendable, Equatable { public let text: String; public let box: CGRect }` — `box` normalized 0…1, origin bottom-left (Vision's and PDF's convention).
  - `PdfBuilder.makePdf(_ pages: [PageImage], text: [[OcrLine]]? = nil) throws -> Data` — with `text`, each page gets its lines as invisible text.
  - `public struct VisionOcrEngine: OcrEngine` with `public init()`, `public static func offeredCodes() -> [String]`, `static func recognize(_ image: CGImage, languages: [String]) throws -> [OcrLine]`.
  - `RawPdf.write(_ pages: [RawPdf.Page]) -> Data`, `RawPdf.Page(jpeg:widthPx:heightPx:dpi:text:)` (text drawn invisible, uncompressed, Helvetica, WinAnsi-safe ASCII only).
  - `public struct FakeOcrEngine: OcrEngine` with `public init(delay: TimeInterval = 2, now: @escaping @Sendable () -> Date = { Date() })`.
  - `ScanDocuments.pdfs: [Data]?` (already-built PDFs, one per document; fake:ocr only) and `ScanDocuments.fakeTexts: [[String]]?` (fake:ocr with `ocr: true` only), both defaulting to `nil` in the init.
  - `FakeScanners.all` gains `fake:ocr` (8 fakes).

- [ ] **Step 1: Failing tests**

`OcrEngineTests.swift`:

```swift
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import HelperCore

/// An A4 page at 150 dpi with the given lines of black 40 px Helvetica text.
private func textPage(_ lines: [String]) throws -> PageImage {
    let width = 1240, height = 1754
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
    for (index, text) in lines.enumerated() {
        let attributed = NSAttributedString(string: text,
                                            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 100, y: height - 200 - index * 80)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    return PageImage(data: try ImageEncoding.jpeg(context.makeImage()!, quality: 0.9), dpi: 150)
}

private func pixels(_ pdf: Data) -> [UInt8] {
    let page = PDFDocument(data: pdf)!.page(at: 0)!
    let box = page.bounds(for: .mediaBox)
    let width = Int(box.width), height = Int(box.height)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    page.draw(with: .mediaBox, to: context)
    return Array(UnsafeBufferPointer(start: context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4),
                                     count: width * height * 4))
}

@Test func offeredCodesAreProtocolCodes() {
    let codes = VisionOcrEngine.offeredCodes()
    #expect(codes.contains("deu") && codes.contains("eng"))
    #expect(codes.allSatisfy { OcrLanguages.visionLanguage(for: $0) != nil })
}

@Test func visionMakesTheTextSearchableAndInvisible() async throws {
    let page = try textPage(["Rechnung Nummer 4711", "Gesamtbetrag 123,45 EUR"])
    let input = OcrJobInput(pages: [page, try textPage([])], languages: ["deu", "eng"], fakeTexts: nil, createdAt: Date())
    let pdf = try await VisionOcrEngine().makeSearchable(input)
    let document = try #require(PDFDocument(data: pdf))
    #expect(document.pageCount == 2)
    let text = document.page(at: 0)?.string ?? ""
    #expect(text.contains("Rechnung Nummer 4711"))
    #expect(text.contains("Gesamtbetrag"))
    // The blank page simply has no text; the job still succeeds.
    #expect((document.page(at: 1)?.string ?? "").isEmpty)
    // Invisible: the page looks exactly like the plain scan.
    #expect(pixels(pdf) == pixels(try PdfBuilder.makePdf([page, try textPage([])])))
    // The text sits where it is on the page (upper part, left side).
    let found = try #require(document.findString("Gesamtbetrag", withOptions: []).first)
    let bounds = found.bounds(for: document.page(at: 0)!)
    #expect(bounds.minY > 600 && bounds.minX < 100)
}

@Test func unreadablePageFailsTheJob() async {
    let input = OcrJobInput(pages: [PageImage(data: Data("not an image".utf8), dpi: 300)], languages: [],
                            fakeTexts: nil, createdAt: Date())
    await #expect(throws: ProtocolError.self) { try await VisionOcrEngine().makeSearchable(input) }
}

@Test func rawPdfIsByteSearchableAndOpens() throws {
    let page = try FakePages.render("Flatbed page 1")
    let plain = RawPdf.write([RawPdf.Page(jpeg: page.data, widthPx: 413, heightPx: 585, dpi: 50, text: nil)])
    let searchable = RawPdf.write([RawPdf.Page(jpeg: page.data, widthPx: 413, heightPx: 585, dpi: 50,
                                               text: "Flatbed page 1")])
    #expect(plain.starts(with: Data("%PDF-".utf8)))
    #expect(plain.range(of: Data("Flatbed page 1".utf8)) == nil)
    #expect(searchable.range(of: Data("Flatbed page 1".utf8)) != nil)
    let document = try #require(PDFDocument(data: searchable))
    #expect(document.pageCount == 1)
    #expect(document.string?.contains("Flatbed page 1") == true)
    #expect(pixels(searchable) == pixels(plain))
}

@Test func fakeEngineWaitsTwoSecondsAfterTheScan() async throws {
    let page = try FakePages.render("Flatbed page 1")
    let created = Date()
    let input = OcrJobInput(pages: [page], languages: [], fakeTexts: ["Flatbed page 1"], createdAt: created)
    let pdf = try await FakeOcrEngine().makeSearchable(input)
    #expect(Date().timeIntervalSince(created) >= 1.9)
    #expect(pdf.range(of: Data("Flatbed page 1".utf8)) != nil)
}
```

In `FakeScanTests.swift` add:

```swift
@Test func fakeOcrScanner() async throws {
    let info = try #require(FakeScanners.infos.first { $0.id == "fake:ocr" })
    #expect(info.name == "Fake OCR Scanner" && info.sources == [.flatbed] && !info.duplex)
    #expect(info.ocrLanguages == ["deu", "eng"] && info.extras.isEmpty)
    let backend = FakeBackend()
    let plainSettings = ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 150, extras: [:])
    let plain = try await backend.scan(scannerID: "fake:ocr", settings: plainSettings)
    #expect(plain.pdfs?.first?.range(of: Data("Flatbed page 1".utf8)) != nil)
    #expect(plain.fakeTexts == nil)
    var ocrSettings = plainSettings; ocrSettings.ocr = true
    let withOcr = try await backend.scan(scannerID: "fake:ocr", settings: ocrSettings)
    #expect(withOcr.pdfs?.first?.range(of: Data("Flatbed page 1".utf8)) == nil)
    #expect(withOcr.fakeTexts == [["Flatbed page 1"]])
    // The other fakes still build their PDFs the usual way.
    #expect(try await backend.scan(scannerID: "fake:flatbed", settings: plainSettings).pdfs == nil)
}
```

In `RouterTests.swift` line ~100 change `#expect(list?.count == 7)` to `#expect(list?.count == 8)`.

Run `scripts/test.sh` → compile errors.

- [ ] **Step 2: `ScanDocuments`** (`ScannerBackend.swift`):

```swift
public struct ScanDocuments: Sendable {
    public var documents: [[PageImage]]
    public var partialMessage: String?
    /// Already-built PDFs, one per document (fake:ocr only, so its text stays byte-searchable).
    public var pdfs: [Data]?
    /// fake:ocr with `ocr: true` only: each document's page texts, for FakeOcrEngine.
    public var fakeTexts: [[String]]?
    public init(documents: [[PageImage]], partialMessage: String?, pdfs: [Data]? = nil, fakeTexts: [[String]]? = nil) {
        self.documents = documents; self.partialMessage = partialMessage; self.pdfs = pdfs; self.fakeTexts = fakeTexts
    }
}
```

- [ ] **Step 3: `RawPdf.swift`** — a minimal hand-written PDF (catalog 1, pages 2, font 3, then per page: page, content, image):

```swift
import Foundation

/// A tiny PDF writer for fake:ocr: JPEG pages embedded as is, plus an optional invisible text line in an
/// uncompressed content stream, so the text can be found in the file's bytes (PROTOCOL.md "Fake scanner mode").
/// ASCII text only.
public enum RawPdf {
    public struct Page {
        public let jpeg: Data
        public let widthPx: Int
        public let heightPx: Int
        public let dpi: Int
        public let text: String?
        public init(jpeg: Data, widthPx: Int, heightPx: Int, dpi: Int, text: String?) {
            self.jpeg = jpeg; self.widthPx = widthPx; self.heightPx = heightPx; self.dpi = dpi; self.text = text
        }
    }

    static func number(_ value: Double) -> String { String(format: "%.2f", value) }

    static func escape(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "(", ")", "\\": return "\\" + String(scalar)
            default: return scalar.isASCII && scalar.value >= 32 ? String(scalar) : "?"
            }
        }.joined())
    }

    public static func write(_ pages: [Page]) -> Data {
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: Data) {
            offsets.append(out.count)
            out.append(Data("\(offsets.count) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        func object(_ text: String) { object(Data(text.utf8)) }

        let pageNumbers = pages.indices.map { 4 + $0 * 3 }
        object("<< /Type /Catalog /Pages 2 0 R >>")
        object("<< /Type /Pages /Kids [\(pageNumbers.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>")
        object("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        for (index, page) in pages.enumerated() {
            let number = pageNumbers[index]
            let dpi = Double(max(page.dpi, 1))
            let width = Double(page.widthPx) * 72 / dpi, height = Double(page.heightPx) * 72 / dpi
            object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(RawPdf.number(width)) \(RawPdf.number(height))] "
                   + "/Resources << /Font << /F1 3 0 R >> /XObject << /Im0 \(number + 2) 0 R >> >> "
                   + "/Contents \(number + 1) 0 R >>")
            var content = "q \(RawPdf.number(width)) 0 0 \(RawPdf.number(height)) 0 0 cm /Im0 Do Q\n"
            if let text = page.text {
                content += "BT /F1 12 Tf 3 Tr 36 \(RawPdf.number(height - 48)) Td (\(RawPdf.escape(text))) Tj ET\n"
            }
            object("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
            var image = Data(("<< /Type /XObject /Subtype /Image /Width \(page.widthPx) /Height \(page.heightPx) "
                              + "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode "
                              + "/Length \(page.jpeg.count) >>\nstream\n").utf8)
            image.append(page.jpeg)
            image.append(Data("\nendstream".utf8))
            object(image)
        }
        let xref = out.count
        var trailer = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { trailer += String(format: "%010d 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(trailer.utf8))
        return out
    }
}
```

(`FakePages` draws RGB JPEGs, so `/DeviceRGB` with 3 components is right; `FakePages.width`/`height` are 413×585 at 50 dpi.)

- [ ] **Step 4: `PdfBuilder.makePdf(_:text:)`** — replace the loop body so an optional per-page `[OcrLine]` is drawn invisibly after the image:

```swift
/// One recognized line of text: `box` is normalized (0…1), origin bottom-left, as Vision and PDF both use.
public struct OcrLine: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public init(text: String, box: CGRect) { self.text = text; self.box = box }
}

public enum PdfBuilder {
    public static func makePdf(_ pages: [PageImage], text: [[OcrLine]]? = nil) throws -> Data {
        guard !pages.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ProtocolError(500, "Couldn't create the PDF.")
        }
        for (index, page) in pages.enumerated() {
            guard let source = CGImageSourceCreateWithData(page.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ProtocolError(500, "A scanned page couldn't be read.")
            }
            let dpi = Double(max(page.dpi, 1))
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            if let lines = text?[safe: index] { drawInvisible(lines, in: box, context: context) }
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }

    /// Each line as invisible text (text drawing mode invisible), stretched to its box's width. CoreText falls
    /// back to a system font for scripts Helvetica lacks (Chinese), and CoreGraphics writes a ToUnicode map, so
    /// PDF readers can search and copy it.
    static func drawInvisible(_ lines: [OcrLine], in box: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let rect = CGRect(x: line.box.minX * box.width, y: line.box.minY * box.height,
                              width: line.box.width * box.width, height: line.box.height * box.height)
            guard rect.width > 0, rect.height > 0 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
            let attributed = NSAttributedString(string: line.text,
                                                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let scale = natural > 0 ? rect.width / natural : 1
            context.textMatrix = CGAffineTransform(scaleX: scale, y: 1)
            context.textPosition = CGPoint(x: rect.minX / scale, y: rect.minY + rect.height * 0.2)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }
}

extension Array {
    /// The element at `index`, or nil when out of range. Used by PdfBuilder, FakeOcrEngine and ScanResponse.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
```

Add `import CoreText` to `PdfBuilder.swift`. (Checked by hand on this Mac before writing this plan: this exact drawing gives PDFKit-extractable text, including Chinese through font fallback, and pixel-identical rendering. `context.textPosition` is in text space, which the scaled `textMatrix` stretches horizontally — hence `x / scale`.)

- [ ] **Step 5: `VisionOcrEngine.swift`**:

```swift
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Real text recognition: Vision's accurate recognizer on each page, the lines drawn as invisible text over
/// the unchanged page image. A page Vision can't read is left without text; only an unreadable image fails.
public struct VisionOcrEngine: OcrEngine {
    public init() {}

    /// The protocol codes this Mac's Vision can recognize.
    public static func offeredCodes() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        return OcrLanguages.offered(supportedVision: supported)
    }

    static func recognize(_ image: CGImage, languages: [String]) throws -> [OcrLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OcrLine(text: candidate.string, box: observation.boundingBox)
        }
    }

    public func makeSearchable(_ input: OcrJobInput) async throws -> Data {
        let languages = OcrLanguages.visionLanguages(for: input.languages)
        var text: [[OcrLine]] = []
        for page in input.pages {
            guard let source = CGImageSourceCreateWithData(page.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ProtocolError(500, "A scanned page couldn't be read for text recognition.")
            }
            text.append((try? VisionOcrEngine.recognize(image, languages: languages)) ?? [])
        }
        return try PdfBuilder.makePdf(input.pages, text: text)
    }
}
```

- [ ] **Step 6: `FakeOcrEngine.swift`**:

```swift
import Foundation

/// fake:ocr's engine: done 2 seconds after the scan, with the page texts written into a byte-searchable PDF.
public struct FakeOcrEngine: OcrEngine {
    let delay: TimeInterval
    let now: @Sendable () -> Date
    public init(delay: TimeInterval = 2, now: @escaping @Sendable () -> Date = { Date() }) {
        self.delay = delay; self.now = now
    }

    public func makeSearchable(_ input: OcrJobInput) async throws -> Data {
        let wait = input.createdAt.addingTimeInterval(delay).timeIntervalSince(now())
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        let texts = input.fakeTexts ?? []
        return RawPdf.write(input.pages.enumerated().map { index, page in
            RawPdf.Page(jpeg: page.data, widthPx: FakePages.width, heightPx: FakePages.height, dpi: page.dpi,
                        text: texts[safe: index])
        })
    }
}
```

- [ ] **Step 7: Fakes.** `FakeScanners.make` gains a trailing `ocr: [String] = []` parameter passed as `ocrLanguages: ocr` to `ScannerInfo`; add to `all`, last:

```swift
        make("fake:ocr", "Fake OCR Scanner", [.flatbed], ocr: ["deu", "eng"]),
```

and update its comment/`CommandLineOptions.usage` ("the protocol's eight fake scanners"). In `FakeBackend.scan`, after `let documents = ...`:

```swift
        guard !fake.info.ocrLanguages.isEmpty else {
            return ScanDocuments(documents: documents, partialMessage: plan.partialMessage)
        }
        // fake:ocr writes its own PDFs so the conformance suite can search their bytes: with ocr the plain file
        // has no text (the job adds it), without ocr it carries the page text like any searchable flatbed scan.
        let pdfs = zip(plan.documents, documents).map { texts, pages in
            RawPdf.write(zip(texts, pages).map { text, page in
                RawPdf.Page(jpeg: page.data, widthPx: FakePages.width, heightPx: FakePages.height, dpi: page.dpi,
                            text: settings.ocr ? nil : text)
            })
        }
        return ScanDocuments(documents: documents, partialMessage: plan.partialMessage, pdfs: pdfs,
                             fakeTexts: settings.ocr ? plan.documents : nil)
```

`FakePages.width`/`height` are `static let` without `public`; same module, fine.

- [ ] **Step 8: Run** `scripts/test.sh` → all pass. (The Vision test takes a second or two.)
- [ ] **Step 9: Commit** — `"macOS helper: Vision text recognition engine, invisible text layer, fake:ocr"` (with trailer).

---

### Task 4: Wiring — `/ocr/<job>`, `ocrJob` in scan answers, runtime, docs, version

**Files:**
- Modify: `macos/Sources/HelperCore/Router.swift`, `macos/Sources/HelperCore/ScanResponse.swift`, `macos/Sources/HelperCore/HelperRuntime.swift`, `macos/Sources/HelperCore/Version.swift`
- Modify: `macos/README.md`, `docs/manual-check-macos.md`, `README.md` (repo root: only where it describes the macOS helper's fakes or features)
- Test: `macos/Tests/HelperCoreTests/RouterTests.swift` (add), `macos/Tests/HelperCoreTests/FakeScanTests.swift` (existing `ScanResponse.payload` tests keep compiling)

**Interfaces:**
- Consumes: everything above.
- Produces: `Router.init(backend:pairing:ocrJobs:ocrLanguages:now:log:)` with `ocrJobs: OcrJobQueue? = nil, ocrLanguages: [String] = []` (languages added to every scanner that has none of its own; `[]` in fake mode); `ScanResponse.files(_:date:) throws -> [ScanResponse.File]`, `ScanResponse.payload(_:files:ocrJobs:)`, and the existing `ScanResponse.payload(_:date:)` kept as a wrapper; `HelperRuntime.ocrJobs: OcrJobQueue`.

- [ ] **Step 1: Failing router tests** (add to `RouterTests.swift`; `makeRouter` gains an `ocrJobs` parameter):

```swift
private func makeOcrRouter() async -> (Router, String) {
    let pairing = PairingStore(mode: .fake)
    let token = try! pairing.pair(code: "000000", client: nil)
    let queue = OcrJobQueue(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("router-ocr-\(UUID().uuidString)"), engine: FakeOcrEngine(delay: 0.3))
    await queue.start()
    return (Router(backend: FakeBackend(), pairing: pairing, ocrJobs: queue), token)
}

@Test func ocrJobLifecycle() async throws {
    let (router, token) = await makeOcrRouter()
    let scan = object(await router.handle(req("POST", "/scan", token: token,
                                              body: #"{"scanner":"fake:ocr","ocr":true,"ocrLanguages":["deu"]}"#)))
    let file = try #require((scan["files"] as? [[String: Any]])?.first)
    let job = try #require(file["ocrJob"] as? String)
    #expect(OcrJobQueue.isValidID(job))
    let pending = await router.handle(req("GET", "/ocr/\(job)", origin: "null", token: token))
    #expect(pending.status == 202)
    #expect(pending.header("Access-Control-Allow-Origin") == "null")
    #expect(object(pending)["state"] as? String != nil && object(pending)["position"] as? Int == 0)
    try await Task.sleep(nanoseconds: 600_000_000)
    let done = await router.handle(req("GET", "/ocr/\(job)", token: token))
    #expect(done.status == 200)
    let out = try #require((object(done)["files"] as? [[String: Any]])?.first)
    #expect(out["name"] as? String == file["name"] as? String)
    #expect(out["pages"] as? Int == 1)
    #expect((await router.handle(req("GET", "/ocr/\(job)", token: token))).status == 404)
}

@Test func ocrEndpointRules() async {
    let (router, token) = await makeOcrRouter()
    #expect((await router.handle(req("GET", "/ocr/no-such-job-0000000000000"))).status == 401)
    #expect((await router.handle(req("GET", "/ocr/no-such-job-0000000000000", token: token))).status == 404)
    #expect((await router.handle(req("GET", "/ocr/", token: token))).status == 404)
    #expect((await router.handle(req("GET", "/ocr", token: token))).status == 404)
    #expect((await router.handle(req("GET", "/ocr/a/b", token: token))).status == 404)
    let post = await router.handle(req("POST", "/ocr/no-such-job-0000000000000", token: token, body: "{}"))
    #expect(post.status == 405)
    #expect(post.header("Allow") == "GET, OPTIONS")
}

@Test func scanWithoutOcrHasNoJobs() async throws {
    let (router, token) = await makeOcrRouter()
    let scan = object(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:ocr"}"#)))
    let file = try #require((scan["files"] as? [[String: Any]])?.first)
    #expect(file["ocrJob"] == nil)
}

@Test func realScannersGetTheEngineLanguages() async {
    let pairing = PairingStore(mode: .fake)
    let token = try! pairing.pair(code: "000000", client: nil)
    let queue = OcrJobQueue(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("router-ocr-\(UUID().uuidString)"), engine: FakeOcrEngine())
    let router = Router(backend: FakeBackend(), pairing: pairing, ocrJobs: queue, ocrLanguages: ["eng"])
    let list = object(await router.handle(req("GET", "/scanners", token: token)))["scanners"] as? [[String: Any]] ?? []
    let flatbed = list.first { $0["id"] as? String == "fake:flatbed" }
    let ocr = list.first { $0["id"] as? String == "fake:ocr" }
    #expect((flatbed?["ocr"] as? [String: Any])?["languages"] as? [String] == ["eng"])
    #expect((ocr?["ocr"] as? [String: Any])?["languages"] as? [String] == ["deu", "eng"])  // its own list wins
}
```

Run `scripts/test.sh` → fails to compile.

- [ ] **Step 2: `ScanResponse`** — split file building from the payload so the router can add jobs between them:

```swift
public enum ScanResponse {
    public struct File {
        public let name: String
        public let pages: [PageImage]
        public let pdf: Data
        public let fakeTexts: [String]?
    }

    public static func pagesMessage(_ count: Int) -> String {
        count == 1 ? "1 page scanned." : "\(count) pages scanned."
    }

    public static func files(_ result: ScanDocuments, date: Date) throws -> [File] {
        let kept = result.documents.indices.filter { !result.documents[$0].isEmpty }
        guard !kept.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: date)
        return try kept.enumerated().map { position, index in
            let pages = result.documents[index]
            let name = kept.count == 1 ? "scan_\(stamp).pdf" : "scan_\(stamp)_\(position + 1).pdf"
            let pdf = try result.pdfs?[safe: index] ?? PdfBuilder.makePdf(pages)
            return File(name: name, pages: pages, pdf: pdf, fakeTexts: result.fakeTexts?[safe: index])
        }
    }

    /// `ocrJobs[i]` is file i's job id, or nil when it has none.
    public static func payload(_ result: ScanDocuments, files: [File], ocrJobs: [String?] = []) -> [String: Any] {
        let entries: [[String: Any]] = files.enumerated().map { index, file in
            var entry: [String: Any] = ["name": file.name, "pages": file.pages.count,
                                        "data": file.pdf.base64EncodedString()]
            if let job = ocrJobs[safe: index] ?? nil { entry["ocrJob"] = job }
            return entry
        }
        let total = files.reduce(0) { $0 + $1.pages.count }
        let partial = result.partialMessage != nil
        return ["ok": !partial, "partial": partial,
                "message": result.partialMessage ?? pagesMessage(total), "files": entries]
    }

    public static func payload(_ result: ScanDocuments, date: Date) throws -> [String: Any] {
        payload(result, files: try files(result, date: date))
    }
}
```

- [ ] **Step 3: `Router`**

- Stored `private let ocrJobs: OcrJobQueue?` and `private let ocrLanguages: [String]`; init parameters `ocrJobs: OcrJobQueue? = nil, ocrLanguages: [String] = []` placed after `pairing:`.
- `endpoints` gains `"/ocr/*": "GET"`; `needsToken` gains `"/ocr/*"`.
- Endpoint lookup:

```swift
    /// "/ocr/<job>" is one endpoint, "/ocr/*"; "/ocr", "/ocr/" and deeper paths are unknown.
    static func endpointKey(_ path: String) -> String? {
        if endpoints[path] != nil { return path }
        if path.hasPrefix("/ocr/") {
            let id = path.dropFirst("/ocr/".count)
            if !id.isEmpty && !id.contains("/") { return "/ocr/*" }
        }
        return nil
    }
```

  In `handle`: `guard let key = Router.endpointKey(request.path), let method = Router.endpoints[key] else { 404 }`, `Router.needsToken.contains(key)`, and `switch key` with a new `case "/ocr/*": return await ocr(String(request.path.dropFirst("/ocr/".count)), origin: origin)`.
- A scanner list that adds the engine's languages to scanners without their own; use it in `/scanners` and `scan()`:

```swift
    /// The backend's scanners as offered: without a job queue nothing offers `ocr` (fake:ocr included);
    /// with one, scanners without their own list get the engine's languages.
    private func scanners() async -> [ScannerInfo] {
        await backend.listScanners().map { scanner in
            var scanner = scanner
            if ocrJobs == nil { scanner.ocrLanguages = [] }
            else if scanner.ocrLanguages.isEmpty { scanner.ocrLanguages = ocrLanguages }
            return scanner
        }
    }
```
- `scan()` after `await gate.end()`:

```swift
        let files = try ScanResponse.files(result, date: now())
        var jobs: [String?] = []
        if settings.ocr, let ocrJobs {
            for file in files {
                do {
                    jobs.append(try await ocrJobs.submit(pages: file.pages, name: file.name,
                                                         languages: settings.ocrLanguages, fakeTexts: file.fakeTexts))
                } catch {
                    // The scan succeeded; the file goes out without a job and the client makes it searchable itself.
                    log("Couldn't queue text recognition for \(file.name): \(error.localizedDescription)")
                    jobs.append(nil)
                }
            }
        }
        let payload = ScanResponse.payload(result, files: files, ocrJobs: jobs)
```

- The handler:

```swift
    private func ocr(_ id: String, origin: String?) async -> HTTPResponse {
        let unknown = Router.errorBody("This text recognition job is unknown, already fetched, or expired.")
        guard let ocrJobs else { return .json(404, unknown, origin: origin) }
        switch await ocrJobs.fetch(id) {
        case .pending(let state, let position):
            return .json(202, ["ok": true, "state": state, "position": position], origin: origin)
        case .done(let name, let pages, let pdf):
            return .json(200, ["ok": true, "files": [["name": name, "pages": pages, "data": pdf.base64EncodedString()]]],
                         origin: origin)
        case .failed(let message):
            return .json(500, Router.errorBody(message), origin: origin)
        case .unknown:
            return .json(404, unknown, origin: origin)
        }
    }
```

- The 405 branch's `Allow` header uses `method` from the key, so `/ocr/<job>` gets `GET, OPTIONS` without further change; check the scan log line still reads well and add `settings.ocr ? ", searchable" : ""`.

- [ ] **Step 4: `HelperRuntime`**

```swift
    public let ocrJobs: OcrJobQueue
    ...
        let write: @Sendable (String) -> Void = { [log] in log.write($0) }
        let ocrLanguages: [String]
        if options.fakeScanners {
            // Fake mode keeps its jobs in a fresh temporary folder: nothing from a test run lingers.
            ocrJobs = OcrJobQueue(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("dossiary-scan-helper-fake-ocr-\(UUID().uuidString)"),
                                  engine: FakeOcrEngine(), log: write)
            ocrLanguages = []
        } else {
            ocrJobs = OcrJobQueue(root: OcrJobQueue.defaultRoot, engine: VisionOcrEngine(), log: write)
            ocrLanguages = VisionOcrEngine.offeredCodes()
        }
        router = Router(backend: backend, pairing: pairing, ocrJobs: ocrJobs, ocrLanguages: ocrLanguages, log: write)
```

  (`write` moves above its first use.) In `start()`, after `server.start()`: `Task { [ocrJobs] in await ocrJobs.start() }`.

- [ ] **Step 5: Version and docs**
  - `Version.swift`: `"0.2.0"`.
  - `macos/README.md`: intro gains one sentence — "With Dossiary's "Make scans searchable automatically", scans come back at once and the helper makes them searchable in the background with macOS's own text recognition (Vision); results wait in `~/Library/Application Support/dossiary-scan-helper/ocr-jobs/` until Dossiary fetches them, at most 7 days." and "seven fake scanners" → "eight fake scanners".
  - `docs/manual-check-macos.md`: add, after the gray/black & white line:
    - `- [ ] With "Make scans searchable automatically" on in Dossiary: the scan arrives at once marked "Making searchable…", and within a minute it's searchable (search for a word on the page); the plain scan is kept as the original.`
    - `- [ ] Quit the helper while a scan is still being made searchable, start it again: it finishes.`
  - Repo-root `README.md`: only if it lists the macOS helper's features or its fake count; leave the reference-helper text alone.

- [ ] **Step 6: Run** `scripts/test.sh` → all pass. `PORT=8797 scripts/run-conformance.sh` → all OK, **none skipped** (the OCR class now runs). If any conformance OCR test fails, fix the helper, not the suite.
- [ ] **Step 7: Commit** — `"macOS helper 0.2.0: GET /ocr/<job>, ocrJob per file, Vision jobs in the background"` (with trailer).

---

### Task 5: Hardware check (owner present)

- [ ] `cd macos && swift build -c release && .build/release/dossiary-scan-helper` (or `scripts/build-app.sh` and open the unsigned app): the menu lists the scanner; `curl -s http://127.0.0.1:8766/health` shows `0.2.0`; `GET /scanners` (paired) shows `"ocr": {"languages": [...]}` on it.
- [ ] From Dossiary with "Make scans searchable automatically" on: a flatbed page and (if the scanner has one) a 3-sheet feeder scan arrive at once marked "Making searchable…", become searchable within a minute, keep the plain scan as the original, and look identical to before.
- [ ] Quit the helper while a job waits, start it again: the job finishes.
- [ ] A page in French or Chinese with that OCR language chosen in Field Settings: the text is found by a search.
