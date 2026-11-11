# Scan Profiles in the Helper's Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Dossiary Scan Helper's menu lists scan profiles; clicking one scans with that profile (Pi scanners and the Mac's own) and saves the file in the profile's folder; a form creates and edits profiles.

**Architecture:** `Router` exposes its `/scan` and `/ocr/<job>` logic as `performScan` / `performOCR` so a profile scan runs exactly like a scan from Dossiary. New HelperCore types: `ScanProfile`, `ScanProfileStore`, `ScanProfileRules` (what a scanner offers, normalizing, request body), `ProfileScanRunner` (scan, wait for OCR, save). The menu gets profile entries through `MenuModel`; AppKit panels (`ScanProfilesPanel`, `ProfileFormPanel`) edit profiles. Spec: `docs/superpowers/specs/2026-11-11-helper-scan-profiles-design.md`.

**Tech Stack:** Swift (SwiftPM, no Xcode), Swift Testing (`import Testing`, `@Test`, `#expect`), AppKit, macOS 14+. Run from `macos/`: `scripts/test.sh` (all unit tests), `swift test --filter <TestName>` (one suite), `python3 -m unittest discover -s scripts -p 'test_*.py'` (localization script tests).

## Global Constraints

- The protocol does not change: `PROTOCOL.md`, `reference/` and `conformance/` stay untouched.
- User-visible text in the macOS app goes through `Texts` / `L(...)` and `macos/Localization/Localizable.xcstrings` (the English text is the key). All seven languages stay complete: en, de, es, fr, zh-Hans, zh-Hant, hy. The localization tests fail on missing translations, changed placeholders or unknown keys. Messages sent to Dossiary stay English.
- Use positional placeholders (`%1$@`, `%2$@`) in any text with two or more arguments.
- A scan from a profile goes through `Router.performScan`; never talk to a scanner or the Pi from the runner directly.
- Never overwrite a scan file (use `ButtonScanFolder.save`).
- Helper version becomes `0.7.0` (`HelperVersion.string`).
- No secrets, tokens or personal data in code, tests or docs.
- Commit after every task, on the current branch, message style `feat: …` / `fix: …` / `docs: …`.

---

### Task 1: Router: `performScan`, `performOCR`, `offeredScanners`

**Files:**
- Modify: `macos/Sources/HelperCore/Router.swift` (`scan(_:origin:)` at ~line 108 and `ocr(_:origin:)` at ~line 160)
- Create: `macos/Tests/HelperCoreTests/RouterPerformScanTests.swift`

**Interfaces:**
- Produces:
  - `public func performScan(_ body: Any) async throws -> (status: Int, payload: [String: Any])` (throws `ProtocolError`)
  - `public func performOCR(_ id: String) async -> (status: Int, body: [String: Any])`
  - `public func offeredScanners() async -> [ScannerInfo]`

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/HelperCoreTests/RouterPerformScanTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

private func makeRouter() -> Router { Router(backend: FakeBackend(), pairing: PairingStore(mode: .fake)) }

@Test func performScanRunsAScanWithoutHTTP() async throws {
    let body: [String: Any] = ["scanner": "fake:flatbed"]
    let (status, payload) = try await makeRouter().performScan(body)
    #expect(status == 200)
    let files = try #require(payload["files"] as? [[String: Any]])
    #expect(files.count == 1)
    #expect((files[0]["name"] as? String)?.hasSuffix(".pdf") == true)
    #expect((files[0]["data"] as? String)?.isEmpty == false)
}

@Test func performScanThrowsTheProtocolErrors() async {
    let body: [String: Any] = ["scanner": "no-such-scanner"]
    await #expect(throws: ProtocolError.self) { _ = try await makeRouter().performScan(body) }
}

@Test func offeredScannersListsTheBackendsScanners() async {
    let ids = await makeRouter().offeredScanners().map(\.id)
    #expect(ids.contains("fake:flatbed"))
    #expect(ids.contains("fake:feeder"))
}

@Test func performOCRAnswers404ForAnUnknownJob() async {
    let (status, _) = await makeRouter().performOCR("does-not-exist-0123456789")
    #expect(status == 404)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run (from `macos/`): `swift test --filter RouterPerformScanTests`
Expected: FAIL to compile with "value of type 'Router' has no member 'performScan'".

- [ ] **Step 3: Refactor `Router.swift`**

Replace the private `scan(_:origin:)` with a thin wrapper plus the public `performScan`, keeping the body of the old function unchanged except for its first line and its returns. The old function starts `private func scan(_ request: HTTPRequest, origin: String?) async throws -> HTTPResponse {` and begins with `let body = try request.jsonBody()`. New code:

```swift
    private func scan(_ request: HTTPRequest, origin: String?) async throws -> HTTPResponse {
        let (status, payload) = try await performScan(try request.jsonBody())
        return .json(status, payload, origin: origin)
    }

    /// POST /scan without HTTP: validation, the scan gate, a local or network scanner, OCR jobs. The HTTP route and
    /// the helper's own profile scans both run it, so a profile scan behaves exactly like one from Dossiary.
    public func performScan(_ body: Any) async throws -> (status: Int, payload: [String: Any]) {
        let (scanner, settings) = try ScanRequestValidator.validate(body, scanners: await scanners())
        // … the rest of the old function, unchanged, with these two changes:
        //   1. in the `if let remote, remote.owns(scanner.id)` branch: `return .json(status, payload, origin: origin)`
        //      becomes `return (status, payload)`
        //   2. the last line `return .json(200, payload, origin: origin)` becomes `return (200, payload)`
    }

    /// The scanners as GET /scanners offers them (OCR languages filled in), for the helper's own menu and form.
    public func offeredScanners() async -> [ScannerInfo] { await scanners() }
```

Then split `ocr(_:origin:)` the same way:

```swift
    private func ocr(_ id: String, origin: String?) async -> HTTPResponse {
        let (status, body) = await performOCR(id)
        return .json(status, body, origin: origin)
    }

    /// GET /ocr/<job> without HTTP.
    public func performOCR(_ id: String) async -> (status: Int, body: [String: Any]) {
        if let remote, remote.isRemoteJob(id) {
            return await remote.fetchOCR(id)
        }
        let unknown = Router.errorBody("This text recognition job is unknown, already fetched, or expired.")
        guard let ocrJobs else { return (404, unknown) }
        switch await ocrJobs.fetch(id) {
        case .pending(let state, let position):
            return (202, ["ok": true, "state": state, "position": position])
        case .done(let name, let pages, let pdf):
            return (200, ["ok": true, "files": [["name": name, "pages": pages, "data": pdf.base64EncodedString()]]])
        case .failed(let message):
            return (500, Router.errorBody(message))
        case .unknown:
            return (404, unknown)
        }
    }
```

(`remote.fetchOCR` already returns `(Int, [String: Any])`, which converts to the labelled tuple.)

- [ ] **Step 4: Run the new and the existing router tests**

Run: `swift test --filter RouterPerformScanTests` then `swift test --filter RouterTests` then `swift test --filter ServerTests`
Expected: all PASS (the HTTP behaviour is unchanged).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/Router.swift macos/Tests/HelperCoreTests/RouterPerformScanTests.swift
git commit -m "feat: Router.performScan and performOCR run a scan without HTTP"
```

---

### Task 2: Save scans of any format into any folder

`ButtonScanFolder.save` always saves into its own folder and forces `.pdf`. Profiles need their own folder and `.jpg`/`.png`.

**Files:**
- Modify: `macos/Sources/HelperCore/ButtonScanFolder.swift` (`save` at ~line 37, `safeName` at ~line 81)
- Create: `macos/Tests/HelperCoreTests/ScanFileSaveTests.swift`

**Interfaces:**
- Produces:
  - `ButtonScanFolder.safeName(_ name: String, extensions: [String] = ["pdf"]) -> String`
  - `ButtonScanFolder.save(_ data: Data, named name: String, into target: URL? = nil, extensions: [String] = ["pdf"]) throws -> URL` (`target` nil means the button-scan folder, as before)

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/HelperCoreTests/ScanFileSaveTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ScanFileSaveTests`
Expected: FAIL to compile (`extra argument 'extensions'` / `'into'`).

- [ ] **Step 3: Implement**

In `ButtonScanFolder.swift` change the two signatures and their uses.

`save`:

```swift
    /// Writes `data` as a new file named after `name` in `target` (default: the button-scan folder) and returns its
    /// URL; never overwrites. `extensions` are the suffixes a name may keep (see `safeName`).
    public func save(_ data: Data, named name: String, into target: URL? = nil, extensions: [String] = ["pdf"]) throws -> URL {
        try lock.withLock {
            let fm = FileManager.default
            let folder = target ?? url
            let safe = Self.safeName(name, extensions: extensions)
            // … the rest of the function is unchanged
```

`safeName` (replace the whole function from its doc comment down):

```swift
    /// Pure: the safe file name for a server-supplied name. Keeps the last path component, removes control and
    /// format characters (Cc, Cf), turns ":" into "-", trims blanks, never starts with ".", ends in one of
    /// `extensions` (the first one is appended when none matches; `["pdf"]` by default) and is at most 200 UTF-8
    /// bytes (cut on a character boundary); an empty result becomes "scan.<first extension>".
    public static func safeName(_ name: String, extensions: [String] = ["pdf"]) -> String {
        var s = name.unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
            .map { String($0) }.joined()
        s = s.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        s = s.replacingOccurrences(of: ":", with: "-")
        while true {
            let before = s
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasPrefix(".") { s.removeFirst() }
            if s == before { break }
        }
        let first = extensions.first ?? "pdf"
        if s.isEmpty { return "scan.\(first)" }
        let kept = extensions.first { s.lowercased().hasSuffix(".\($0)") } ?? first
        if !s.lowercased().hasSuffix(".\(kept)") { s += ".\(kept)" }
        if s.utf8.count > 200 {
            let suffixLength = kept.count + 1               // extensions are ASCII
            let suffix = String(s.suffix(suffixLength))
            var base = String(s.dropLast(suffixLength))
            while base.utf8.count + suffix.utf8.count > 200 { base.removeLast() }
            s = base + suffix
        }
        return s
    }
```

- [ ] **Step 4: Run the new tests and the old ones**

Run: `swift test --filter ScanFileSaveTests` then `swift test --filter ButtonScanFolderTests` then `swift test --filter ButtonScanPickupTests`
Expected: all PASS (default behaviour unchanged).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/ButtonScanFolder.swift macos/Tests/HelperCoreTests/ScanFileSaveTests.swift
git commit -m "feat: save scans of any format into any folder"
```

---

### Task 3: `ScanProfile`, `ScanProfileStore`, `ScanProfileRules`

**Files:**
- Modify: `macos/Sources/HelperCore/Model.swift` (lines 3-4: make `Source` and `ColorMode` `Codable`)
- Create: `macos/Sources/HelperCore/ScanProfile.swift`
- Create: `macos/Sources/HelperCore/ScanProfileStore.swift`
- Create: `macos/Sources/HelperCore/ScanProfileRules.swift`
- Create: `macos/Tests/HelperCoreTests/ScanProfileRulesTests.swift`
- Create: `macos/Tests/HelperCoreTests/ScanProfileStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct ScanProfile: Codable, Equatable, Identifiable, Sendable` with fields `id, name, scannerID, scannerName, destination: String; source: Source; duplex: Bool; colorMode: ColorMode; resolution: Int; format: String; area: String?; ocr: Bool; ocrLanguages: [String]` and `init(id: String = UUID().uuidString, name:, scannerID:, scannerName:, destination:, source:, duplex: Bool = false, colorMode:, resolution:, format: String = "pdf", area: String? = nil, ocr: Bool = false, ocrLanguages: [String] = [])`
  - `struct ProfileOptions: Equatable, Sendable` with `sources: [Source]`, `duplexOffered: Bool`, `colorModes: [ColorMode]`, `resolutions: [Int]`, `formats: [String]`, `areas: [String]`, `ocrOffered: Bool`, `ocrLanguages: [String]`
  - `enum ScanProfileRules` with `static func options(for: ScannerInfo, source: Source, colorMode: ColorMode) -> ProfileOptions`, `static func normalized(_ profile: ScanProfile, for scanner: ScannerInfo) -> ScanProfile`, `static func requestBody(_ profile: ScanProfile) -> [String: Any]` (expects a normalized profile), `static func placeholderScanner(for profile: ScanProfile) -> ScannerInfo`
  - `final class ScanProfileStore: @unchecked Sendable` with `static var defaultFileURL: URL`, `init(fileURL: URL?)`, `var profiles: [ScanProfile]`, `func profile(id: String) -> ScanProfile?`, `func save(_ profile: ScanProfile) throws` (insert or replace by id), `func remove(id: String) throws`

- [ ] **Step 1: Make `Source` and `ColorMode` Codable**

In `Model.swift` change

```swift
public enum Source: String, Sendable { case flatbed, feeder }
public enum ColorMode: String, Sendable { case color, gray, bw }
```
to
```swift
public enum Source: String, Sendable, Codable { case flatbed, feeder }
public enum ColorMode: String, Sendable, Codable { case color, gray, bw }
```

- [ ] **Step 2: Write the failing rules tests**

Create `macos/Tests/HelperCoreTests/ScanProfileRulesTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

/// What scanix500-server lists for the Canon CanoScan 8800F on a Pi.
private let flatbedPi = ScannerInfo(
    id: "remote:srv:sane:canoscan-8800f", name: "Canon CanoScan 8800F (node-000)", sources: [.flatbed], duplex: false,
    colorModes: [.color, .gray, .bw], resolutions: [150, 300, 600, 1200], extras: [], ocrLanguages: ["deu", "eng"],
    formats: ["pdf", "jpeg", "png"], areas: ["full", "a4", "a5", "a6", "10x15", "13x18"])

/// …and for the iX500.
private let feederPi = ScannerInfo(
    id: "remote:srv:sane:ix500", name: "ScanSnap iX500 (node-000)", sources: [.feeder], duplex: true,
    colorModes: [.color, .gray, .bw], resolutions: [150, 200, 300, 400, 600], extras: ["splitOnBlank"],
    ocrLanguages: ["deu", "eng"], formats: ["pdf"], areas: [])

private func profile(_ scanner: ScannerInfo, source: Source = .flatbed, duplex: Bool = false, color: ColorMode = .color,
                     resolution: Int = 300, format: String = "pdf", area: String? = nil, ocr: Bool = false,
                     languages: [String] = []) -> ScanProfile {
    ScanProfile(name: "p", scannerID: scanner.id, scannerName: scanner.name, destination: "/tmp/x", source: source,
                duplex: duplex, colorMode: color, resolution: resolution, format: format, area: area, ocr: ocr,
                ocrLanguages: languages)
}

@Test func aFlatbedOffersImagesButNoJpegInBlackAndWhite() {
    #expect(ScanProfileRules.options(for: flatbedPi, source: .flatbed, colorMode: .color).formats == ["pdf", "jpeg", "png"])
    #expect(ScanProfileRules.options(for: flatbedPi, source: .flatbed, colorMode: .bw).formats == ["pdf", "png"])
}

@Test func aFeederOffersOnlyPdfAndDuplex() {
    let options = ScanProfileRules.options(for: feederPi, source: .feeder, colorMode: .color)
    #expect(options.formats == ["pdf"])
    #expect(options.duplexOffered)
    #expect(options.areas.isEmpty)
    #expect(!ScanProfileRules.options(for: flatbedPi, source: .flatbed, colorMode: .color).duplexOffered)
}

@Test func normalizingDropsWhatTheScannerCannot() {
    let p = ScanProfileRules.normalized(profile(flatbedPi, duplex: true, resolution: 250, format: "jpeg", area: "nope",
                                                ocr: true, languages: ["fra"]), for: flatbedPi)
    #expect(!p.duplex)                       // a flatbed has no duplex
    #expect(p.resolution == 300)             // nearest offered
    #expect(p.area == "full")                // unknown area -> the first offered
    #expect(!p.ocr && p.ocrLanguages.isEmpty)   // OCR is only for PDF
    #expect(p.format == "jpeg")
}

@Test func normalizingFixesJpegInBlackAndWhiteAndImagesFromAFeeder() {
    #expect(ScanProfileRules.normalized(profile(flatbedPi, color: .bw, format: "jpeg"), for: flatbedPi).format == "pdf")
    #expect(ScanProfileRules.normalized(profile(feederPi, source: .feeder, format: "png"), for: feederPi).format == "pdf")
}

@Test func normalizingMovesAProfileToAnotherScanner() {
    let p = ScanProfileRules.normalized(profile(flatbedPi, format: "png", area: "a4", resolution: 1200), for: feederPi)
    #expect(p.scannerID == feederPi.id && p.scannerName == feederPi.name)
    #expect(p.source == .feeder)
    #expect(p.format == "pdf")
    #expect(p.area == nil)
    #expect(p.resolution == 600)
}

@Test func normalizingKeepsAndFiltersOcrLanguages() {
    let kept = ScanProfileRules.normalized(profile(feederPi, source: .feeder, ocr: true, languages: ["eng", "fra"]), for: feederPi)
    #expect(kept.ocr && kept.ocrLanguages == ["eng"])
    let defaulted = ScanProfileRules.normalized(profile(feederPi, source: .feeder, ocr: true, languages: []), for: feederPi)
    #expect(defaulted.ocrLanguages == ["deu", "eng"])
}

@Test func theRequestBodyIsWhatTheValidatorAccepts() throws {
    let cases: [(ScannerInfo, ScanProfile)] = [
        (flatbedPi, profile(flatbedPi, format: "jpeg", area: "a4")),
        (flatbedPi, profile(flatbedPi, color: .bw, resolution: 600, format: "png", area: "10x15")),
        (flatbedPi, profile(flatbedPi, area: "full", ocr: true, languages: ["deu"])),
        (feederPi, profile(feederPi, source: .feeder, duplex: true, ocr: true, languages: ["deu", "eng"])),
    ]
    for (scanner, raw) in cases {
        let p = ScanProfileRules.normalized(raw, for: scanner)
        let body = ScanProfileRules.requestBody(p)
        let (found, settings) = try ScanRequestValidator.validate(body, scanners: [scanner])
        #expect(found.id == scanner.id)
        #expect(settings.format == p.format)
        #expect(settings.ocr == p.ocr)
        #expect(settings.duplex == p.duplex)
    }
}

@Test func theRequestBodyLeavesOutDefaults() {
    let body = ScanProfileRules.requestBody(ScanProfileRules.normalized(profile(feederPi, source: .feeder), for: feederPi))
    #expect(body["format"] == nil && body["area"] == nil && body["ocr"] == nil && body["duplex"] == nil)
    #expect(body["scanner"] as? String == feederPi.id)
}

@Test func aPlaceholderScannerKeepsAProfilesChoices() {
    let p = ScanProfileRules.normalized(profile(flatbedPi, format: "png", area: "a4"), for: flatbedPi)
    let placeholder = ScanProfileRules.placeholderScanner(for: p)
    #expect(placeholder.id == p.scannerID && placeholder.name == p.scannerName)
    #expect(ScanProfileRules.normalized(p, for: placeholder) == p)
}
```

- [ ] **Step 3: Write the failing store tests**

Create `macos/Tests/HelperCoreTests/ScanProfileStoreTests.swift`:

```swift
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
```

- [ ] **Step 4: Run both to verify they fail**

Run: `swift test --filter ScanProfileRulesTests` and `swift test --filter ScanProfileStoreTests`
Expected: FAIL to compile (`cannot find 'ScanProfile' in scope`).

- [ ] **Step 5: Implement `ScanProfile.swift`**

```swift
import Foundation

/// A saved way of scanning: which scanner, how, and where the file goes.
public struct ScanProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var scannerID: String
    /// Remembered so the menu can name the scanner even while it is off or unreachable.
    public var scannerName: String
    /// A folder path.
    public var destination: String
    public var source: Source
    public var duplex: Bool
    public var colorMode: ColorMode
    public var resolution: Int
    /// "pdf", "jpeg" or "png".
    public var format: String
    /// An area id (see `Areas`); nil for a scanner without areas.
    public var area: String?
    public var ocr: Bool
    public var ocrLanguages: [String]

    public init(id: String = UUID().uuidString, name: String, scannerID: String, scannerName: String, destination: String,
                source: Source, duplex: Bool = false, colorMode: ColorMode, resolution: Int, format: String = "pdf",
                area: String? = nil, ocr: Bool = false, ocrLanguages: [String] = []) {
        self.id = id; self.name = name; self.scannerID = scannerID; self.scannerName = scannerName
        self.destination = destination; self.source = source; self.duplex = duplex; self.colorMode = colorMode
        self.resolution = resolution; self.format = format; self.area = area; self.ocr = ocr
        self.ocrLanguages = ocrLanguages
    }
}
```

- [ ] **Step 6: Implement `ScanProfileRules.swift`**

```swift
import Foundation

/// What the profile form offers for a scanner and the choices made so far.
public struct ProfileOptions: Equatable, Sendable {
    public var sources: [Source]
    public var duplexOffered: Bool
    public var colorModes: [ColorMode]
    public var resolutions: [Int]
    public var formats: [String]
    public var areas: [String]
    public var ocrOffered: Bool
    public var ocrLanguages: [String]
}

/// The rules of PROTOCOL.md "Request validation" applied to profiles: what a scanner offers, how to make a profile
/// fit a scanner, and the POST /scan body a profile stands for.
public enum ScanProfileRules {
    /// Duplex only from a duplex feeder; images only from the flatbed and never JPEG in black and white;
    /// OCR is offered when the scanner lists languages (the caller also needs format "pdf").
    public static func options(for scanner: ScannerInfo, source: Source, colorMode: ColorMode) -> ProfileOptions {
        let formats = scanner.formats.filter { format in
            if format == "pdf" { return true }
            if source == .feeder { return false }
            return !(format == "jpeg" && colorMode == .bw)
        }
        return ProfileOptions(sources: scanner.sources, duplexOffered: scanner.duplex && source == .feeder,
                              colorModes: scanner.colorModes, resolutions: scanner.resolutions, formats: formats,
                              areas: scanner.areas, ocrOffered: !scanner.ocrLanguages.isEmpty,
                              ocrLanguages: scanner.ocrLanguages)
    }

    /// `profile` made to fit `scanner`: every choice the scanner doesn't offer is replaced by the nearest or first
    /// one it does. Idempotent.
    public static func normalized(_ profile: ScanProfile, for scanner: ScannerInfo) -> ScanProfile {
        var p = profile
        p.scannerID = scanner.id
        p.scannerName = scanner.name
        if !scanner.sources.contains(p.source) { p.source = scanner.sources.first ?? .flatbed }
        if !scanner.colorModes.contains(p.colorMode) { p.colorMode = scanner.colorModes.first ?? .color }
        let o = options(for: scanner, source: p.source, colorMode: p.colorMode)
        if !o.resolutions.contains(p.resolution) { p.resolution = nearest(p.resolution, in: o.resolutions) }
        if !o.formats.contains(p.format) { p.format = "pdf" }
        p.duplex = p.duplex && o.duplexOffered
        if o.areas.isEmpty { p.area = nil }
        else if p.area.map(o.areas.contains) != true { p.area = o.areas[0] }
        if p.format == "pdf" && o.ocrOffered {
            p.ocrLanguages = p.ocrLanguages.filter(o.ocrLanguages.contains)
            if p.ocr && p.ocrLanguages.isEmpty { p.ocrLanguages = defaultLanguages(offered: o.ocrLanguages) }
        } else {
            p.ocr = false
            p.ocrLanguages = []
        }
        return p
    }

    /// The POST /scan body for a profile already normalized to its scanner; defaults are left out.
    public static func requestBody(_ p: ScanProfile) -> [String: Any] {
        var body: [String: Any] = ["scanner": p.scannerID, "source": p.source.rawValue,
                                   "colorMode": p.colorMode.rawValue, "resolution": p.resolution]
        if p.duplex { body["duplex"] = true }
        if p.format != "pdf" { body["format"] = p.format }
        if let area = p.area { body["area"] = area }
        if p.ocr { body["ocr"] = true; body["ocrLanguages"] = p.ocrLanguages }
        return body
    }

    /// A stand-in for a scanner that is off or unreachable: it offers exactly the profile's own choices, so the form
    /// can still change the name and folder without touching the rest.
    public static func placeholderScanner(for p: ScanProfile) -> ScannerInfo {
        ScannerInfo(id: p.scannerID, name: p.scannerName, sources: [p.source], duplex: p.duplex, colorModes: [p.colorMode],
                    resolutions: [p.resolution], extras: [], ocrLanguages: p.ocr ? p.ocrLanguages : [],
                    formats: [p.format], areas: p.area.map { [$0] } ?? [])
    }

    private static func nearest(_ value: Int, in list: [Int]) -> Int {
        list.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    private static func defaultLanguages(offered: [String]) -> [String] {
        let preferred = ["deu", "eng"].filter(offered.contains)
        return preferred.isEmpty ? Array(offered.prefix(1)) : preferred
    }
}
```

- [ ] **Step 7: Implement `ScanProfileStore.swift`**

```swift
import Foundation

/// The scan profiles (profiles.json in Application Support); fileURL nil keeps them in memory.
public final class ScanProfileStore: @unchecked Sendable {
    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dossiary-scan-helper")
            .appendingPathComponent("profiles.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var items: [ScanProfile] = []

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([ScanProfile].self, from: data) {
            items = saved
        } else {
            // Never lose what a person typed: keep the unreadable file next to the new, empty one.
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("profiles.json.unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    public var profiles: [ScanProfile] { lock.withLock { items } }

    public func profile(id: String) -> ScanProfile? { lock.withLock { items.first { $0.id == id } } }

    /// Adds the profile, or replaces the one with the same id.
    public func save(_ profile: ScanProfile) throws {
        try lock.withLock {
            if let index = items.firstIndex(where: { $0.id == profile.id }) { items[index] = profile }
            else { items.append(profile) }
            try write()
        }
    }

    public func remove(id: String) throws {
        try lock.withLock {
            items.removeAll { $0.id == id }
            try write()
        }
    }

    /// Call with the lock held.
    private func write() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 8: Run the tests**

Run: `swift test --filter ScanProfileRulesTests` and `swift test --filter ScanProfileStoreTests`
Expected: all PASS. If `normalizingDropsWhatTheScannerCannot` fails on the resolution, re-read `nearest` (250 → 300 is distance 50, 150 is 100).

- [ ] **Step 9: Commit**

```bash
git add macos/Sources/HelperCore macos/Tests/HelperCoreTests
git commit -m "feat: scan profiles, their store and the rules that fit them to a scanner"
```

---

### Task 4: `ProfileScanRunner`

**Files:**
- Create: `macos/Sources/HelperCore/ProfileScanRunner.swift`
- Create: `macos/Tests/HelperCoreTests/ProfileScanRunnerTests.swift`

**Interfaces:**
- Consumes: `Router.performScan`, `Router.performOCR`, `Router.offeredScanners` (Task 1); `ButtonScanFolder.save(_:named:into:extensions:)` (Task 2); `ScanProfile`, `ScanProfileRules` (Task 3)
- Produces:
  - `enum ProfileScanOutcome: Equatable, Sendable` with cases `saved(files: [URL], pages: Int, searchable: Bool?)` (`searchable` is nil when no OCR was asked for), `partial(files: [URL], message: String)`, `failed(String)`
  - `final class ProfileScanRunner: @unchecked Sendable` with `init(router: Router, writer: ButtonScanFolder, clock: @escaping @Sendable () -> Date = Date.init, ocrPollSeconds: Double = 2, ocrGiveUpSeconds: Double = 600)`, `var onChange: (@Sendable () -> Void)?`, `var runningProfileID: String?`, `var isRunning: Bool`, `func run(_ profile: ScanProfile) async -> ProfileScanOutcome`

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/HelperCoreTests/ProfileScanRunnerTests.swift`:

```swift
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

    init(withOcr: Bool = false, giveUp: Double = 0.2) async {
        var jobs: OcrJobQueue?
        if withOcr {
            jobs = OcrJobQueue(root: tempFolder(), engine: FakeOcrEngine(), log: { _ in })
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
    #expect(outcome == .failed("Canon CanoScan 8800F (node-000) isn't available right now."))
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
    #expect(files.count == 1 && !message.isEmpty)
}

@Test func onlyOneProfileScanRunsAtATime() async {
    let rig = await Rig()
    defer { rig.cleanup() }
    let slow = rig.profile("fake:slow", name: "Fake Slow Scanner")
    async let first = rig.runner.run(slow)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(rig.runner.isRunning)
    let second = await rig.runner.run(slow)
    #expect(second == .failed("Another profile scan is still running."))
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
```

Note for the implementer: `FakeBackend` behaviour per fake scanner is in `FakeScanners.all` / `FakeBackend.swift` (`fake:jam` jams after 2 sheets of 3 and answers a partial result with 2 pages; `fake:offline` throws 503; `fake:slow` delays 2 s). If a test's assumption about a fake scanner is off, read that file and adjust the assertion, not the production code.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ProfileScanRunnerTests`
Expected: FAIL to compile (`cannot find 'ProfileScanRunner' in scope`).

- [ ] **Step 3: Implement `ProfileScanRunner.swift`**

```swift
import Foundation

public enum ProfileScanOutcome: Equatable, Sendable {
    /// `searchable` is nil when no text recognition was asked for, true when every file got its text layer,
    /// false when at least one stayed a plain scan.
    case saved(files: [URL], pages: Int, searchable: Bool?)
    /// Something went wrong but usable pages were saved.
    case partial(files: [URL], message: String)
    case failed(String)
}

/// Runs a scan profile: scan through the router (so exactly like a scan from Dossiary), wait for each file's text
/// recognition, save the files in the profile's folder. One profile scan at a time.
public final class ProfileScanRunner: @unchecked Sendable {
    private static let extensions = ["pdf", "jpg", "png"]

    private let router: Router
    private let writer: ButtonScanFolder
    private let clock: @Sendable () -> Date
    private let ocrPollSeconds: Double
    private let ocrGiveUpSeconds: Double
    private let lock = NSLock()
    private var running: String?

    /// Called, on any thread, when a profile scan starts and when it ends (the menu refreshes itself).
    public var onChange: (@Sendable () -> Void)?

    public init(router: Router, writer: ButtonScanFolder, clock: @escaping @Sendable () -> Date = Date.init,
                ocrPollSeconds: Double = 2, ocrGiveUpSeconds: Double = 600) {
        self.router = router; self.writer = writer; self.clock = clock
        self.ocrPollSeconds = ocrPollSeconds; self.ocrGiveUpSeconds = ocrGiveUpSeconds
    }

    public var runningProfileID: String? { lock.withLock { running } }
    public var isRunning: Bool { runningProfileID != nil }

    public func run(_ profile: ScanProfile) async -> ProfileScanOutcome {
        guard begin(profile.id) else { return .failed("Another profile scan is still running.") }
        onChange?()
        defer { end(); onChange?() }
        do {
            guard let scanner = await router.offeredScanners().first(where: { $0.id == profile.scannerID }) else {
                return .failed("\(profile.scannerName) isn't available right now.")
            }
            let fitted = ScanProfileRules.normalized(profile, for: scanner)
            let (status, payload) = try await router.performScan(ScanProfileRules.requestBody(fitted))
            guard status == 200 else { return .failed(payload["message"] as? String ?? "The scan failed.") }
            guard let entries = payload["files"] as? [[String: Any]], !entries.isEmpty else {
                return .failed(payload["message"] as? String ?? "The scanner returned no pages.")
            }
            let stamp = Self.stamp(clock())
            var saved: [URL] = []
            var pages = 0
            var allSearchable = true
            for (index, entry) in entries.enumerated() {
                guard var bytes = Data(base64Encoded: entry["data"] as? String ?? "") else {
                    return .failed("The scan couldn't be read.")
                }
                if fitted.ocr, let job = entry["ocrJob"] as? String {
                    if let searchable = await searchableCopy(job) { bytes = searchable } else { allSearchable = false }
                } else if fitted.ocr {
                    allSearchable = false
                }
                let ext = (entry["name"] as? String).map { ($0 as NSString).pathExtension.lowercased() }
                    .flatMap { Self.extensions.contains($0) ? $0 : nil } ?? "pdf"
                let suffix = entries.count > 1 ? "_\(index + 1)" : ""
                let url = try writer.save(bytes, named: "scan_\(stamp)\(suffix).\(ext)",
                                          into: URL(fileURLWithPath: fitted.destination, isDirectory: true),
                                          extensions: Self.extensions)
                saved.append(url)
                pages += entry["pages"] as? Int ?? 1
            }
            if payload["ok"] as? Bool == false {
                return .partial(files: saved, message: payload["message"] as? String ?? "The scan was incomplete.")
            }
            return .saved(files: saved, pages: pages, searchable: fitted.ocr ? allSearchable : nil)
        } catch let error as ProtocolError {
            return .failed(error.message)
        } catch let error as ButtonScanSaveError {
            return .failed(error.reason)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The searchable PDF for an OCR job, or nil when it failed or took longer than the give-up time (the plain scan
    /// is then kept). A network scanner that can't be reached for a moment (503) is retried until then.
    private func searchableCopy(_ job: String) async -> Data? {
        var waited = 0.0
        while true {
            let (status, body) = await router.performOCR(job)
            switch status {
            case 200:
                guard let files = body["files"] as? [[String: Any]], let first = files.first,
                      let data = Data(base64Encoded: first["data"] as? String ?? "") else { return nil }
                return data
            case 202, 503:
                break
            default:
                return nil
            }
            if waited >= ocrGiveUpSeconds { return nil }
            try? await Task.sleep(nanoseconds: UInt64(ocrPollSeconds * 1_000_000_000))
            waited += ocrPollSeconds
        }
    }

    private func begin(_ id: String) -> Bool {
        lock.withLock {
            guard running == nil else { return false }
            running = id
            return true
        }
    }

    private func end() { lock.withLock { running = nil } }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ProfileScanRunnerTests`
Expected: all PASS. The two-scans test relies on `ButtonScanFolder.save` adding " 2" when a name exists (two scans in the same second).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/ProfileScanRunner.swift macos/Tests/HelperCoreTests/ProfileScanRunnerTests.swift
git commit -m "feat: ProfileScanRunner scans with a profile, waits for OCR and saves the file"
```

---

### Task 5: Menu entries and texts

**Files:**
- Modify: `macos/Sources/HelperCore/MenuModel.swift`
- Modify: `macos/Sources/HelperCore/Texts.swift` (add `profileScanSummary`)
- Create: `macos/Tests/HelperCoreTests/ProfileMenuTests.swift`

**Interfaces:**
- Consumes: `ProfileScanOutcome` (Task 4)
- Produces:
  - `MenuAction` gains `case scanWithProfile(String)` and `case editProfiles`
  - `struct ProfileMenuEntry: Equatable, Sendable` with `id: String`, `name: String`, `scannerName: String`, `scanning: Bool` and a public memberwise `init(id:name:scannerName:scanning:)`
  - `MenuModel.entries(...)` gains the parameters `profiles: [ProfileMenuEntry]? = nil, profileScanRunning: Bool = false, lastProfileScan: String? = nil, profileProblem: String? = nil` (placed before `texts:`)
  - `Texts.profileScanSummary(_ outcome: ProfileScanOutcome) -> (title: String, body: String)`

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/HelperCoreTests/ProfileMenuTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

private func entries(profiles: [ProfileMenuEntry]?, running: Bool = false, last: String? = nil, problem: String? = nil) -> [MenuEntry] {
    MenuModel.entries(scanners: [], port: 8766, fake: false, pairedCount: 0, startAtLogin: nil, profiles: profiles,
                      profileScanRunning: running, lastProfileScan: last, profileProblem: problem)
}

@Test func noProfilesParameterMeansNoProfileSection() {
    let all = entries(profiles: nil)
    #expect(!all.contains(.action("Scan profiles…", .editProfiles, checked: false, enabled: true)))
}

@Test func eachProfileIsAScanEntryAndThereIsAnEditEntry() {
    let all = entries(profiles: [ProfileMenuEntry(id: "a", name: "Letters", scannerName: "Canon CanoScan 8800F (node-000)", scanning: false)])
    #expect(all.contains(.action("Scan: Letters (Canon CanoScan 8800F (node-000))", .scanWithProfile("a"), checked: false, enabled: true)))
    #expect(all.contains(.action("Scan profiles…", .editProfiles, checked: false, enabled: true)))
}

@Test func theRunningProfileSaysSoAndAllScanEntriesAreDisabled() {
    let all = entries(profiles: [ProfileMenuEntry(id: "a", name: "Letters", scannerName: "S", scanning: true),
                                 ProfileMenuEntry(id: "b", name: "Photos", scannerName: "S", scanning: false)], running: true)
    #expect(all.contains(.action("Scanning “Letters”…", .scanWithProfile("a"), checked: false, enabled: false)))
    #expect(all.contains(.action("Scan: Photos (S)", .scanWithProfile("b"), checked: false, enabled: false)))
}

@Test func theLastScanAndAProblemAreShownAsInfoLines() {
    let all = entries(profiles: [], last: "scan_2026-11-11_120000.pdf", problem: "No paper in the feeder.")
    #expect(all.contains(.info("Last profile scan: scan_2026-11-11_120000.pdf")))
    #expect(all.contains(.info("No paper in the feeder.")))
}

private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

@Test func summaryOfASavedScan() {
    let one = Texts.english.profileScanSummary(.saved(files: [url("a.pdf")], pages: 1, searchable: nil))
    #expect(one.title == "1 page scanned" && one.body == "a.pdf")
    let many = Texts.english.profileScanSummary(.saved(files: [url("a.pdf"), url("b.pdf")], pages: 5, searchable: true))
    #expect(many.title == "5 pages scanned" && many.body == "a.pdf, b.pdf")
}

@Test func summaryMentionsMissingText() {
    let s = Texts.english.profileScanSummary(.saved(files: [url("a.pdf")], pages: 2, searchable: false))
    #expect(s.body.hasPrefix("a.pdf"))
    #expect(s.body.contains("text recognition didn't finish"))
}

@Test func summaryOfAPartialAndAFailedScan() {
    let partial = Texts.english.profileScanSummary(.partial(files: [url("a.pdf")], message: "Paper jam."))
    #expect(partial.title == "Scan incomplete" && partial.body.contains("a.pdf") && partial.body.contains("Paper jam."))
    let failed = Texts.english.profileScanSummary(.failed("No paper in the feeder."))
    #expect(failed.title == "Scan failed" && failed.body == "No paper in the feeder.")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ProfileMenuTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement the menu changes**

In `MenuModel.swift`:

1. Add the two cases to `MenuAction`:

```swift
public enum MenuAction: Equatable, Sendable {
    case pair, forget, startAtLogin, openLog, quit, addNetworkScanner, chooseButtonScanFolder, toggleButtonSound
    case removeNetworkScanner(String)
    case scanWithProfile(String)
    case editProfiles
}
```

2. Add the entry type above `MenuEntry`:

```swift
public struct ProfileMenuEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    public let scannerName: String
    public let scanning: Bool
    public init(id: String, name: String, scannerName: String, scanning: Bool) {
        self.id = id; self.name = name; self.scannerName = scannerName; self.scanning = scanning
    }
}
```

3. Add the four parameters to `entries(...)` (before `texts t: Texts = .english`):

```swift
                               profiles: [ProfileMenuEntry]? = nil, profileScanRunning: Bool = false,
                               lastProfileScan: String? = nil, profileProblem: String? = nil,
```

4. Right after the line `entries += scanners.isEmpty ? [.info(t("No scanners found"))] : scanners.map { .info($0.name) }`, before the block that starts with `.separator, .action(t("Pair a browser…")…`, insert:

```swift
        if let profiles {
            entries.append(.separator)
            for profile in profiles {
                let title = profile.scanning ? t("Scanning “%@”…", profile.name)
                                             : t("Scan: %1$@ (%2$@)", profile.name, profile.scannerName)
                entries.append(.action(title, .scanWithProfile(profile.id), checked: false, enabled: !profileScanRunning))
            }
            entries.append(.action(t("Scan profiles…"), .editProfiles, checked: false, enabled: true))
            if let lastProfileScan { entries.append(.info(t("Last profile scan: %@", lastProfileScan))) }
            if let profileProblem { entries.append(.info(profileProblem)) }
        }
```

In `Texts.swift` add inside `Texts`:

```swift
    /// The notification for a finished profile scan. File names and the scanner's own messages are shown as they come.
    public func profileScanSummary(_ outcome: ProfileScanOutcome) -> (title: String, body: String) {
        let t = self
        func names(_ files: [URL]) -> String { files.map(\.lastPathComponent).joined(separator: ", ") }
        switch outcome {
        case .saved(let files, let pages, let searchable):
            let title = pages == 1 ? t("1 page scanned") : t("%lld pages scanned", pages)
            let note = searchable == false ? " — " + t("The scan was saved without searchable text; text recognition didn't finish.") : ""
            return (title, names(files) + note)
        case .partial(let files, let message):
            return (t("Scan incomplete"), names(files) + " — " + message)
        case .failed(let message):
            return (t("Scan failed"), message)
        }
    }
```

(The English key for the missing-text note is `The scan was saved without searchable text; text recognition didn't finish.`; the test checks for `text recognition didn't finish`.)

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ProfileMenuTests` then `swift test --filter MenuModelTests`
Expected: all PASS. If Swift reports the `switch` over `MenuAction` in `App/AppDelegate.swift` as not exhaustive, that is expected here and fixed in Task 6 (SwiftPM builds `HelperCore` tests without the App target, so these test runs still pass).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore macos/Tests/HelperCoreTests/ProfileMenuTests.swift
git commit -m "feat: menu entries for scan profiles and the texts of a finished profile scan"
```

---

### Task 6: The app: runtime wiring, panels, notification, seven languages

**Files:**
- Modify: `macos/Sources/HelperCore/HelperRuntime.swift`
- Modify: `macos/Sources/App/PickupNotifier.swift`
- Modify: `macos/Sources/App/AppDelegate.swift`
- Create: `macos/Sources/App/ProfileFormPanel.swift`
- Create: `macos/Sources/App/ScanProfilesPanel.swift`
- Modify: `macos/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: `HelperRuntime.profileStore: ScanProfileStore`, `HelperRuntime.profileRunner: ProfileScanRunner`; `PickupNotifier.notify(title:body:)`.

- [ ] **Step 1: Wire the runtime**

In `HelperRuntime.swift` add two properties after `public let buttonPressSetting: ButtonPressSetting?`:

```swift
    public let profileStore: ScanProfileStore
    public let profileRunner: ProfileScanRunner
```

and, right after the line `router = Router(backend: backend, pairing: pairing, ocrJobs: ocrJobs, ocrLanguages: ocrLanguages, remote: remote, log: write)` (the statement that spans two lines), before `server = HTTPServer(...)`:

```swift
        // Fake mode keeps its profiles in memory so test runs leave nothing behind.
        profileStore = ScanProfileStore(fileURL: options.fakeScanners ? nil : ScanProfileStore.defaultFileURL)
        profileRunner = ProfileScanRunner(router: router, writer: ButtonScanFolder())
```

Run `swift build` (from `macos/`) and confirm `HelperCore` compiles. (The `App` target fails to compile until Step 4 because of the non-exhaustive `MenuAction` switch; that is expected.)

- [ ] **Step 2: Generalize the notifier**

In `PickupNotifier.swift` replace `notify(_ scan: PickedUpScan)` by two methods; the permission logic stays in one place:

```swift
    func notify(_ scan: PickedUpScan) {
        notify(title: scan.pages == 1 ? L("1 page scanned") : L("%lld pages scanned", scan.pages), body: scan.name)
    }

    /// Any notification of the helper's own (a finished profile scan).
    func notify(title: String, body: String) {
        // A bare executable (swift run) has no bundle for the notification centre.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let firstTime = lock.withLock { () -> Bool in
            defer { asked = true }
            return !asked
        }
        Task {
            if firstTime {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
```

- [ ] **Step 3: Create `ProfileFormPanel.swift`**

```swift
import AppKit
import HelperCore

/// One scan profile as a form. Every popup shows only what the chosen scanner offers: any change re-reads the
/// choices through `ScanProfileRules.normalized` and refills the popups.
final class ProfileFormPanel: NSPanel {
    private let scanners: [ScannerInfo]
    private var draft: ScanProfile
    private let onSave: (ScanProfile) -> Void

    private let nameField = NSTextField()
    private let scannerPopup = NSPopUpButton()
    private let folderField = NSTextField()
    private let sourcePopup = NSPopUpButton()
    private let duplexBox = NSButton(checkboxWithTitle: L("Scan both sides"), target: nil, action: nil)
    private let colorPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let areaPopup = NSPopUpButton()
    private let ocrBox = NSButton(checkboxWithTitle: L("Make the PDF searchable (OCR)"), target: nil, action: nil)
    private let languagesField = NSTextField()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var grid = NSGridView()
    private enum Row: Int { case name, scanner, folder, source, duplex, color, resolution, format, area, ocr, languages }

    /// `scanners` are the scanners to choose from; `draft` the profile to edit (a new one is already normalized).
    init(scanners: [ScannerInfo], draft: ScanProfile, onSave: @escaping (ScanProfile) -> Void) {
        self.scanners = scanners
        self.draft = draft
        self.onSave = onSave
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = L("Scan profiles")
        isReleasedWhenClosed = false
        build()
        reload()
    }

    private var scanner: ScannerInfo? { scanners.first { $0.id == draft.scannerID } }

    private func build() {
        let chooseFolder = NSButton(title: L("Choose"), target: self, action: #selector(chooseFolderClicked))
        folderField.isEditable = false
        let folderRow = NSStackView(views: [folderField, chooseFolder])
        folderRow.spacing = 8
        let save = NSButton(title: L("Save"), target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 12

        func label(_ text: String) -> NSTextField { NSTextField(labelWithString: L(text)) }
        let rows: [[NSView]] = [
            [label("Name"), nameField], [label("Scanner"), scannerPopup], [label("Folder"), folderRow],
            [label("Source"), sourcePopup], [NSView(), duplexBox], [label("Mode"), colorPopup],
            [label("Resolution"), resolutionPopup], [label("Format"), formatPopup], [label("Paper size"), areaPopup],
            [NSView(), ocrBox], [label("OCR languages (codes, e.g. deu, eng)"), languagesField],
        ]
        grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        for popup in [scannerPopup, sourcePopup, colorPopup, resolutionPopup, formatPopup, areaPopup] {
            popup.target = self
            popup.action = #selector(controlChanged(_:))
        }
        scannerPopup.action = #selector(scannerChanged)
        for box in [duplexBox, ocrBox] { box.target = self; box.action = #selector(controlChanged(_:)) }
        messageLabel.textColor = .systemRed
        let stack = NSStackView(views: [grid, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        languagesField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        folderField.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    /// Fills every control from `draft` and hides what the scanner doesn't offer.
    private func reload() {
        nameField.stringValue = draft.name
        folderField.stringValue = draft.destination
        fill(scannerPopup, scanners.map { ($0.id, $0.name) }, selected: draft.scannerID)
        guard let scanner else { return }
        let o = ScanProfileRules.options(for: scanner, source: draft.source, colorMode: draft.colorMode)
        fill(sourcePopup, o.sources.map { ($0.rawValue, $0 == .flatbed ? L("Flatbed") : L("Feeder")) }, selected: draft.source.rawValue)
        fill(colorPopup, o.colorModes.map { ($0.rawValue, Self.colorTitle($0)) }, selected: draft.colorMode.rawValue)
        fill(resolutionPopup, o.resolutions.map { (String($0), L("%lld dpi", $0)) }, selected: String(draft.resolution))
        fill(formatPopup, o.formats.map { ($0, $0.uppercased()) }, selected: draft.format)
        fill(areaPopup, o.areas.map { ($0, Self.areaTitle($0)) }, selected: draft.area)
        duplexBox.state = draft.duplex ? .on : .off
        ocrBox.state = draft.ocr ? .on : .off
        languagesField.stringValue = draft.ocrLanguages.joined(separator: ", ")
        grid.row(at: Row.source.rawValue).isHidden = o.sources.count < 2
        grid.row(at: Row.duplex.rawValue).isHidden = !o.duplexOffered
        grid.row(at: Row.area.rawValue).isHidden = o.areas.isEmpty
        let ocrShown = o.ocrOffered && draft.format == "pdf"
        grid.row(at: Row.ocr.rawValue).isHidden = !ocrShown
        grid.row(at: Row.languages.rawValue).isHidden = !(ocrShown && draft.ocr)
    }

    private func fill(_ popup: NSPopUpButton, _ items: [(String, String)], selected: String?) {
        popup.removeAllItems()
        for (value, title) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        if let index = items.firstIndex(where: { $0.0 == selected }) { popup.selectItem(at: index) }
    }

    private func chosen(_ popup: NSPopUpButton) -> String? { popup.selectedItem?.representedObject as? String }

    private static func colorTitle(_ mode: ColorMode) -> String {
        switch mode {
        case .color: return L("Color")
        case .gray: return L("Grayscale")
        case .bw: return L("Black and white")
        }
    }

    private static func areaTitle(_ id: String) -> String { id == Areas.full ? L("The whole glass") : (Areas.named(id)?.label ?? id) }

    private func readControls() {
        draft.name = nameField.stringValue
        draft.destination = folderField.stringValue
        if let s = chosen(sourcePopup).flatMap(Source.init(rawValue:)) { draft.source = s }
        draft.duplex = duplexBox.state == .on
        if let c = chosen(colorPopup).flatMap(ColorMode.init(rawValue:)) { draft.colorMode = c }
        if let r = chosen(resolutionPopup).flatMap(Int.init) { draft.resolution = r }
        if let f = chosen(formatPopup) { draft.format = f }
        draft.area = chosen(areaPopup)
        draft.ocr = ocrBox.state == .on
        draft.ocrLanguages = languagesField.stringValue.split(whereSeparator: { ", ".contains($0) }).map(String.init)
    }

    @objc private func scannerChanged() {
        readControls()
        draft.scannerID = chosen(scannerPopup) ?? draft.scannerID
        if let scanner { draft = ScanProfileRules.normalized(draft, for: scanner) }
        reload()
    }

    @objc private func controlChanged(_ sender: Any?) {
        readControls()
        if let scanner { draft = ScanProfileRules.normalized(draft, for: scanner) }
        reload()
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folderField.stringValue)
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url { folderField.stringValue = url.path }
    }

    @objc private func saveClicked() {
        readControls()
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { messageLabel.stringValue = L("Give the profile a name."); return }
        guard let scanner else { messageLabel.stringValue = L("Choose a scanner."); return }
        if draft.destination.isEmpty { messageLabel.stringValue = L("Choose a folder."); return }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        onSave(ScanProfileRules.normalized(draft, for: scanner))
        close()
    }

    @objc private func cancelClicked() { close() }

    func show() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 4: Create `ScanProfilesPanel.swift`**

```swift
import AppKit
import HelperCore

/// The list of scan profiles with New…, Edit…, Delete and Done.
final class ScanProfilesPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ScanProfileStore
    private let scanners: () -> [ScannerInfo]
    private let onChange: () -> Void
    private let table = NSTableView()
    private var form: ProfileFormPanel?
    private var editButton = NSButton()
    private var deleteButton = NSButton()

    init(store: ScanProfileStore, scanners: @escaping () -> [ScannerInfo], onChange: @escaping () -> Void) {
        self.store = store
        self.scanners = scanners
        self.onChange = onChange
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = L("Scan profiles")
        isReleasedWhenClosed = false
        build()
    }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.width = 420
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(editClicked)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let new = NSButton(title: L("New…"), target: self, action: #selector(newClicked))
        editButton = NSButton(title: L("Edit…"), target: self, action: #selector(editClicked))
        deleteButton = NSButton(title: L("Delete"), target: self, action: #selector(deleteClicked))
        let done = NSButton(title: L("Done"), target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [new, editButton, deleteButton, NSView(), done])
        buttons.spacing = 8
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
    }

    func show() {
        table.reloadData()
        updateButtons()
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private var selected: ScanProfile? {
        let row = table.selectedRow
        let all = store.profiles
        return all.indices.contains(row) ? all[row] : nil
    }

    private func updateButtons() {
        editButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let profile = store.profiles[row]
        return NSTextField(labelWithString: L("Scan: %1$@ (%2$@)", profile.name, profile.scannerName))
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func newClicked() {
        let available = scanners()
        guard let first = available.first else {
            let alert = NSAlert()
            alert.messageText = L("No scanners are available yet. Add a network scanner or connect one first.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let blank = ScanProfile(name: "", scannerID: first.id, scannerName: first.name,
                                destination: ButtonScanFolder.defaultURL.path, source: .flatbed, colorMode: .color,
                                resolution: 300)
        open(scanners: available, draft: ScanProfileRules.normalized(blank, for: first))
    }

    @objc private func editClicked() {
        guard let profile = selected else { return }
        var available = scanners()
        if !available.contains(where: { $0.id == profile.scannerID }) {
            available.append(ScanProfileRules.placeholderScanner(for: profile))   // off or unreachable: keep its choices
        }
        open(scanners: available, draft: profile)
    }

    private func open(scanners: [ScannerInfo], draft: ScanProfile) {
        let panel = ProfileFormPanel(scanners: scanners, draft: draft) { [weak self] profile in
            guard let self else { return }
            do { try store.save(profile) } catch {
                let alert = NSAlert(error: error)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            table.reloadData()
            updateButtons()
            onChange()
        }
        form = panel
        panel.show()
    }

    @objc private func deleteClicked() {
        guard let profile = selected else { return }
        do { try store.remove(id: profile.id) } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        table.reloadData()
        updateButtons()
        onChange()
    }

    @objc private func doneClicked() { close() }
}
```

- [ ] **Step 5: Wire `AppDelegate.swift`**

Add properties next to `networkPanel`:

```swift
    private lazy var profilesPanel = ScanProfilesPanel(store: runtime.profileStore, scanners: { [weak self] in self?.scanners ?? [] },
                                                       onChange: { })
    private var lastProfileScan: String?
    private var profileProblem: String?
```

(The menu is rebuilt every time it opens, through `menuNeedsUpdate`, so the app doesn't use the runner's `onChange`.)

In `menuNeedsUpdate`, add the new arguments to the `MenuModel.entries(...)` call, before `texts: L`:

```swift
                                        profiles: runtime.profileStore.profiles.map {
                                            ProfileMenuEntry(id: $0.id, name: $0.name, scannerName: $0.scannerName,
                                                             scanning: runtime.profileRunner.runningProfileID == $0.id)
                                        },
                                        profileScanRunning: runtime.profileRunner.isRunning,
                                        lastProfileScan: lastProfileScan,
                                        profileProblem: profileProblem,
```

In `menuItemChosen`, add two cases before `case .quit:`:

```swift
        case .scanWithProfile(let id):
            guard let profile = runtime.profileStore.profile(id: id) else { return }
            Task { [weak self] in
                guard let self else { return }
                let outcome = await runtime.profileRunner.run(profile)
                await MainActor.run { self.profileScanFinished(outcome) }
            }
        case .editProfiles:
            profilesPanel.show()
```

and add the method to `AppDelegate`:

```swift
    private func profileScanFinished(_ outcome: ProfileScanOutcome) {
        switch outcome {
        case .saved(let files, _, _):
            lastProfileScan = files.first?.lastPathComponent
            profileProblem = nil
        case .partial(let files, let message):
            lastProfileScan = files.first?.lastPathComponent
            profileProblem = message
        case .failed(let message):
            profileProblem = message
        }
        let summary = L.profileScanSummary(outcome)
        notifier.notify(title: summary.title, body: summary.body)
    }
```

- [ ] **Step 6: Add the new texts in seven languages**

Run this once from `macos/` (a throwaway script: do not commit it). It adds every new key with its six translations and writes the file exactly like Xcode does:

```bash
python3 - <<'EOF'
import json
path = "Localization/Localizable.xcstrings"
data = json.load(open(path))
LANGS = ["de", "es", "fr", "zh-Hans", "zh-Hant", "hy"]
T = {
 "Scan: %1$@ (%2$@)": ["Scannen: %1$@ (%2$@)", "Escanear: %1$@ (%2$@)", "Numériser : %1$@ (%2$@)", "扫描：%1$@（%2$@）", "掃描：%1$@（%2$@）", "Սկանավորել՝ %1$@ (%2$@)"],
 "Scanning “%@”…": ["„%@“ wird gescannt …", "Escaneando «%@»…", "Numérisation de « %@ »…", "正在扫描“%@”…", "正在掃描「%@」…", "Սկանավորվում է «%@»…"],
 "Scan profiles…": ["Scanprofile …", "Perfiles de escaneo…", "Profils de numérisation…", "扫描配置文件…", "掃描設定檔…", "Սկանավորման պրոֆիլներ…"],
 "Last profile scan: %@": ["Letzter Profil-Scan: %@", "Último escaneo con perfil: %@", "Dernière numérisation avec profil : %@", "最近一次配置文件扫描：%@", "最近一次設定檔掃描：%@", "Վերջին պրոֆիլով սկանավորումը՝ %@"],
 "Scan incomplete": ["Scan unvollständig", "Escaneo incompleto", "Numérisation incomplète", "扫描未完成", "掃描未完成", "Սկանավորումը թերի է"],
 "Scan failed": ["Scan fehlgeschlagen", "Error al escanear", "Échec de la numérisation", "扫描失败", "掃描失敗", "Սկանավորումը ձախողվեց"],
 "The scan was saved without searchable text; text recognition didn't finish.": ["Der Scan wurde ohne durchsuchbaren Text gespeichert; die Texterkennung wurde nicht fertig.", "El escaneo se guardó sin texto buscable; el reconocimiento de texto no terminó.", "La numérisation a été enregistrée sans texte recherchable ; la reconnaissance de texte n'a pas abouti.", "扫描已保存，但没有可搜索的文字；文字识别未完成。", "掃描已儲存，但沒有可搜尋的文字；文字辨識未完成。", "Սկանավորումը պահպանվեց առանց որոնելի տեքստի. տեքստի ճանաչումը չավարտվեց։"],
 "Scan profiles": ["Scanprofile", "Perfiles de escaneo", "Profils de numérisation", "扫描配置文件", "掃描設定檔", "Սկանավորման պրոֆիլներ"],
 "New…": ["Neu …", "Nuevo…", "Nouveau…", "新建…", "新增…", "Նոր…"],
 "Edit…": ["Bearbeiten …", "Editar…", "Modifier…", "编辑…", "編輯…", "Խմբագրել…"],
 "Delete": ["Löschen", "Eliminar", "Supprimer", "删除", "刪除", "Ջնջել"],
 "Done": ["Fertig", "Hecho", "Terminé", "完成", "完成", "Պատրաստ է"],
 "Name": ["Name", "Nombre", "Nom", "名称", "名稱", "Անուն"],
 "Scanner": ["Scanner", "Escáner", "Scanner", "扫描仪", "掃描器", "Սկաներ"],
 "Folder": ["Ordner", "Carpeta", "Dossier", "文件夹", "資料夾", "Պանակ"],
 "Source": ["Quelle", "Origen", "Source", "来源", "來源", "Աղբյուր"],
 "Flatbed": ["Flachbett", "Cama plana", "À plat", "平板", "平台", "Հարթ մակերես"],
 "Feeder": ["Einzug", "Alimentador", "Chargeur", "进纸器", "進紙器", "Թղթի սնուցիչ"],
 "Scan both sides": ["Beide Seiten scannen", "Escanear ambas caras", "Numériser recto verso", "扫描双面", "掃描雙面", "Սկանավորել երկու կողմերը"],
 "Mode": ["Modus", "Modo", "Mode", "模式", "模式", "Ռեժիմ"],
 "Color": ["Farbe", "Color", "Couleur", "彩色", "彩色", "Գունավոր"],
 "Grayscale": ["Graustufen", "Escala de grises", "Niveaux de gris", "灰度", "灰階", "Մոխրագույն"],
 "Black and white": ["Schwarzweiß", "Blanco y negro", "Noir et blanc", "黑白", "黑白", "Սև-սպիտակ"],
 "Resolution": ["Auflösung", "Resolución", "Résolution", "分辨率", "解析度", "Լուծաչափ"],
 "%lld dpi": ["%lld dpi", "%lld dpi", "%lld dpi", "%lld dpi", "%lld dpi", "%lld dpi"],
 "Format": ["Format", "Formato", "Format", "格式", "格式", "Ձևաչափ"],
 "Paper size": ["Papiergröße", "Tamaño del papel", "Format du papier", "纸张大小", "紙張大小", "Թղթի չափս"],
 "The whole glass": ["Ganze Glasfläche", "Todo el cristal", "Toute la vitre", "整个玻璃面", "整個玻璃面", "Ամբողջ ապակին"],
 "Make the PDF searchable (OCR)": ["PDF durchsuchbar machen (OCR)", "Hacer el PDF buscable (OCR)", "Rendre le PDF recherchable (OCR)", "生成可搜索的 PDF（OCR）", "產生可搜尋的 PDF（OCR）", "Դարձնել PDF-ը որոնելի (OCR)"],
 "OCR languages (codes, e.g. deu, eng)": ["OCR-Sprachen (Kürzel, z. B. deu, eng)", "Idiomas de OCR (códigos, p. ej. deu, eng)", "Langues de l'OCR (codes, p. ex. deu, eng)", "OCR 语言（代码，例如 deu、eng）", "OCR 語言（代碼，例如 deu、eng）", "OCR լեզուներ (կոդեր, օր.՝ deu, eng)"],
 "Save": ["Speichern", "Guardar", "Enregistrer", "存储", "儲存", "Պահպանել"],
 "Cancel": ["Abbrechen", "Cancelar", "Annuler", "取消", "取消", "Չեղարկել"],
 "Give the profile a name.": ["Das Profil braucht einen Namen.", "El perfil necesita un nombre.", "Le profil doit avoir un nom.", "请为配置文件输入名称。", "請為設定檔輸入名稱。", "Պրոֆիլին անուն է պետք։"],
 "Choose a scanner.": ["Ein Scanner muss gewählt werden.", "Se debe elegir un escáner.", "Choisissez un scanner.", "请选择扫描仪。", "請選擇掃描器。", "Ընտրեք սկաներ։"],
 "Choose a folder.": ["Ein Ordner muss gewählt werden.", "Se debe elegir una carpeta.", "Choisissez un dossier.", "请选择文件夹。", "請選擇資料夾。", "Ընտրեք պանակ։"],
 "No scanners are available yet. Add a network scanner or connect one first.": ["Noch kein Scanner verfügbar. Zuerst einen Netzwerkscanner hinzufügen oder einen anschließen.", "Aún no hay escáneres disponibles. Primero se debe añadir un escáner de red o conectar uno.", "Aucun scanner disponible pour l'instant. Ajoutez d'abord un scanner réseau ou branchez-en un.", "暂无可用的扫描仪。请先添加网络扫描仪或连接一台。", "目前沒有可用的掃描器。請先新增網路掃描器或連接一台。", "Դեռ հասանելի սկաներ չկա։ Նախ ավելացրեք ցանցային սկաներ կամ միացրեք մեկը։"],
}
for key, values in T.items():
    assert key not in data["strings"], key
    data["strings"][key] = {"localizations": {lang: {"stringUnit": {"state": "translated", "value": v}} for lang, v in zip(LANGS, values)}}
open(path, "w").write(json.dumps(data, indent=2, ensure_ascii=False, separators=(",", ": ")) + "\n")
print(len(T), "keys added")
EOF
git diff --stat Localization/Localizable.xcstrings
```

Expected: `36 keys added` and a diff that only adds lines (no existing line changed). If the `assert` fires, a key already exists: delete that entry from `T` and carry on.

- [ ] **Step 7: Build, run all tests and the localization checks**

Run (from `macos/`): `swift build` then `scripts/test.sh` then `python3 -m unittest discover -s scripts -p 'test_*.py'`
Expected: build succeeds, all tests PASS (about 40 new). Then `scripts/build-app.sh` followed by `scripts/check-localized-app.sh` (see `macos/README.md`; it checks the built app's translations) — expected PASS.

- [ ] **Step 8: Run the helper with fake scanners and look at it**

Run: `swift run dossiary-scan-helper --fake-scanners` (menu bar icon appears).
Check by hand: menu shows "Scan profiles…"; New… → form lists the fake scanners (Fake Flatbed, Fake Feeder, …); choosing "Fake Feeder" shows Source and "Scan both sides"; choosing "Fake Photo Scanner" shows Format and Paper size; save a profile with a folder in `/tmp`; the menu now has "Scan: <name> (<scanner>)"; clicking it saves a PDF in that folder and shows a notification only when run as an app (bare `swift run` has none: the menu line "Last profile scan" is the proof).

- [ ] **Step 9: Commit**

```bash
git add macos
git commit -m "feat: scan profiles in the menu: panels, notification and seven languages"
```

---

### Task 7: Docs, version, hardware checklist

**Files:**
- Modify: `macos/Sources/HelperCore/Version.swift` (`0.7.0`)
- Modify: `AGENTS.md`, `macos/README.md`, `docs/manual-check-macos.md`, `docs/install-macos.md` (only where they list the menu or features)
- Modify: every test or doc that contains the old version string

- [ ] **Step 1: Bump the version**

In `Version.swift` set `public static let string = "0.7.0"`. Find other occurrences:

Run: `grep -rn "0\.6\.2" . --exclude-dir=.build --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=superpowers`
Update each hit that names the helper's current version (tests of `/health`, README install examples). Leave historical mentions in `docs/superpowers`.

- [ ] **Step 2: Document the feature**

- `AGENTS.md` (Conventions): add a bullet after the "Button press sound" one:

```
- Scan profiles (0.7.0): the menu lists profiles (`ScanProfileStore`, `profiles.json` in Application Support) and "Scan profiles…"
  opens the editor (`ScanProfilesPanel`, `ProfileFormPanel`). `ProfileScanRunner` scans through `Router.performScan`
  (so exactly like a scan from Dossiary), waits for each file's OCR job (give up after 10 minutes, keep the plain scan)
  and saves with `ButtonScanFolder.save(…, into:)`. `ScanProfileRules` is the one place that knows what a scanner offers.
```
- `macos/README.md`: a short "Scan profiles" section: what a profile holds, "Scan profiles…" window, files named `scan_YYYY-MM-DD_HHMMSS.<ext>`, Pi scanners need the Pi to be added with "Add network scanner…".
- `docs/manual-check-macos.md`: read its format first, then append a section "Scan profiles (0.7.0)" with these checks, written in the file's style:
  1. With the Pi's 8800F on and node-000 added: New… lists "Canon CanoScan 8800F (node-000)"; the form offers PDF, JPEG, PNG and paper sizes, no "Scan both sides".
  2. Save a profile "8800F A4 JPEG" into a test folder; click it; the menu shows "Scanning “8800F A4 JPEG”…" and the other entries are greyed; a notification "1 page scanned" appears and a `.jpg` is in the folder.
  3. A PDF profile with "Make the PDF searchable (OCR)": the PDF is saved after the Pi's text recognition and its text can be selected in Preview.
  4. The iX500 on the Pi with "Scan both sides": a feeder scan saves one PDF with all pages.
  5. Switch the 8800F off and click a profile: a "Scan failed" notification names the reason and nothing is saved.
  6. Start a scan from Dossiary and click a profile at the same time: the profile reports "Another scan is still running" (only for scanners on the same Mac; two Pis' scanners are independent).
  7. Edit a profile whose scanner is off: name and folder can change, the rest stays.
  8. Quit and reopen the helper: the profiles are still there.

- [ ] **Step 3: Run everything**

Run (from `macos/`): `scripts/test.sh` then `python3 -m unittest discover -s scripts -p 'test_*.py'` then `scripts/run-conformance.sh`
Expected: all PASS (the conformance suite proves the HTTP behaviour did not change).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs: scan profiles; helper 0.7.0"
```

---

## Self-review

- **Spec coverage:** one scan path (Task 1); profile store/rules/body (Task 3); saving any format into the profile's folder, never overwriting (Task 2, 4); running, OCR wait, partial/failed outcomes, one scan at a time, onChange (Task 4); menu entries, "Scanning…", last scan, problem line, notification texts (Task 5, 6); the form with only-offered choices, placeholder scanner for an off scanner, unreadable-file handling (Task 3, 6); seven languages (Task 6); docs, version, checklist (Task 7). Not in scope items stay out.
- **Placeholder scan:** no TBD/TODO; every code step shows the code. Task 1 step 3 describes two mechanical edits inside an existing function by exact old and new lines because the function body is unchanged and long.
- **Type consistency:** `ScanProfile` fields, `ProfileOptions`, `ScanProfileRules.options/normalized/requestBody/placeholderScanner`, `ProfileScanOutcome` cases, `ProfileScanRunner.run/runningProfileID/isRunning/onChange`, `ProfileMenuEntry(id:name:scannerName:scanning:)`, `MenuAction.scanWithProfile/editProfiles`, `Texts.profileScanSummary`, `ButtonScanFolder.save(_:named:into:extensions:)` and `safeName(_:extensions:)`, `Router.performScan/performOCR/offeredScanners` are used with the same names and labels in every task.
- **Known judgement calls for the implementer:** the form's OCR languages are a comma-separated text field (kept simple on purpose); the profile list shows "Scan: name (scanner)" as its row text; `ButtonScanFolder` is reused for its safe atomic save even though the profile folder is not the button-scan folder.
