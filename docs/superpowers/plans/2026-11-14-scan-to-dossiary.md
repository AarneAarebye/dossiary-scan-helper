# Scan to Dossiary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scan profile with "Also send to Dossiary" hands its saved scan to the Dossiary Mac app, which adds it to the library it has open.

**Architecture:** Two repos. Mac app (`dossiary-osx`, 0.5.1): an `NSApplicationDelegateAdaptor` receives the system's open-documents event, a MacCore `HandOverQueue` filters and holds the files until a library is open, and `AppModel` adds them through its existing `addFiles` path. Helper (`dossiary-scan-helper`, 0.8.0): `ScanProfile.sendToDossiary`, `ProfileScanRunner.runAndHandOver` (HelperCore, testable) and `DossiaryHandOver` (App, `NSWorkspace.open(_:withApplicationAt:)`).

**Tech Stack:** Swift (SwiftPM helper with Swift Testing; Mac app SwiftUI + XcodeGen + XCUITest + MacCore XCTest), the helper's `Localizable.xcstrings` and the Mac app's `scripts/make_strings.py`.

Spec: `docs/superpowers/specs/2026-11-14-scan-to-dossiary-design.md` (this repo).

## Global Constraints

- The Mac app is `com.aarneaarebye.dossiary-mac` (`/Applications/Dossiary/Dossiary.app`). The hand-over uses the standard open-documents event, **never a custom URL scheme** (a web page could trigger it).
- The helper never writes into a library; it only saves in the profile's folder and opens the saved files with the app. The folder copy stays; the Mac app never moves or deletes handed-over files.
- Hand over only the files actually saved (`.saved` or `.partial`); nothing after a failed scan; a failed hand-over never changes whether the scan counts as saved.
- Mac app: only existing regular files with extensions `pdf, jpg, jpeg, png, tif, tiff, heic` are accepted; the files wait until a library is open; with no library available the app shows "Open a library to add the scan. It is saved in your scan folder." and adds nothing.
- All new user-visible texts are translated in all seven languages (en, de, es, fr, zh-Hans, zh-Hant, hy). Helper: `macos/Localization/Localizable.xcstrings` (English text is the key; the localization tests fail on missing translations; labels must use literal `L("…")`). Mac: `scripts/make_strings.py` (`NEW` dict + `KEYS`), then regenerate `App/Localizable.xcstrings`.
- Existing `profiles.json` files must load unchanged (`sendToDossiary` optional, default false).
- Run the repo's tests before each commit: helper `cd macos && swift test` (269+ tests, a few timing tests are flaky once in a while: re-run before judging); Mac `cd MacCore && swift test` and the app's `xcodebuild … test`. Playwright/Python is not involved.
- No tag, push or release unless the human partner asks. Versions: helper `macos/Sources/HelperCore/Version.swift` 0.8.0; Mac `project.yml` `MARKETING_VERSION` "0.5.1", `CURRENT_PROJECT_VERSION` "18" (regenerate with `/opt/homebrew/bin/xcodegen generate`, commit the project).
- Repos: helper `/Users/aarneaarebye/Projects/Paperless/dossiary-scan-helper`, Mac `/Users/aarneaarebye/Projects/Paperless/dossiary-osx`; each task commits only in the repo it names.

---

### Task 1: Mac app — `HandOverQueue` (MacCore)

**Repo:** `dossiary-osx`

**Files:**
- Create: `MacCore/Sources/MacCore/HandOverQueue.swift`
- Create: `MacCore/Tests/MacCoreTests/HandOverQueueTests.swift`

**Interfaces:**
- Produces:
  - `public struct HandOverQueue: Equatable, Sendable { public static let supportedExtensions: Set<String>; public private(set) var pending: [URL]; public init(); public var isEmpty: Bool; public static func acceptable(_ urls: [URL]) -> [URL]; public mutating func receive(_ urls: [URL]); public mutating func takeAll() -> [URL] }`

- [ ] **Step 1: Write the failing tests** (`HandOverQueueTests`, XCTest, temp files cleaned with `addTeardownBlock`)

1. `testAcceptsExistingFilesOfSupportedTypes` — pdf, JPG (upper case), png, tiff, heic files that exist are kept in order.
2. `testDropsMissingFoldersAndUnsupportedTypes` — a missing path, a folder, `a.rtf`, `a.docx`, a file with no extension are dropped.
3. `testReceiveKeepsOrderAndSkipsDuplicates` — receiving the same URL twice (also via two different spellings of the same path) queues it once.
4. `testTakeAllEmptiesTheQueue` — `takeAll()` returns the files and leaves `isEmpty == true`; a second call returns `[]`.
5. `testReceivingNothingAcceptableLeavesItEmpty`.

- [ ] **Step 2: Run to see failures** — `cd MacCore && swift test --filter HandOverQueueTests 2>&1 | tail -15` (expected: compile errors).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Files another app (the Scan Helper) handed to the Mac app, waiting until a library is open to take them.
public struct HandOverQueue: Equatable, Sendable {
    /// What the adder can read (DossiaryCore's `LocalDocumentAdder`: PDFs and images).
    public static let supportedExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "tif", "tiff", "heic"]

    public private(set) var pending: [URL] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// Existing regular files of a supported type, in the given order, each path once.
    public static func acceptable(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard supportedExtensions.contains(url.pathExtension.lowercased()), !seen.contains(path) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            seen.insert(path)
            result.append(url)
        }
        return result
    }

    public mutating func receive(_ urls: [URL]) {
        let known = Set(pending.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        pending += Self.acceptable(urls).filter { !known.contains($0.standardizedFileURL.resolvingSymlinksInPath().path) }
    }

    public mutating func takeAll() -> [URL] {
        defer { pending = [] }
        return pending
    }
}
```

- [ ] **Step 4: Run all MacCore tests** — `cd MacCore && swift test 2>&1 | tail -6`; all pass (194 existing + 5 new).

- [ ] **Step 5: Commit** (`dossiary-osx`)

```bash
git add MacCore
git commit -m "feat(mac): HandOverQueue holds files handed over by another app until a library is open"
```

---

### Task 2: Mac app — receive the hand-over, add it, name the library

**Repo:** `dossiary-osx`

**Files:**
- Create: `App/DossiaryAppDelegate.swift`
- Modify: `App/DossiaryMacApp.swift`, `App/AppModel.swift`, `scripts/make_strings.py`, regenerated `App/Localizable.xcstrings`, `UITests/DossiaryMacUITests.swift`, `project.yml` + `Dossiary.xcodeproj`, `AGENTS.md`, `README.md`, `docs/parity-checklist.md`

**Interfaces:**
- Consumes: `HandOverQueue` (Task 1); `AppModel.addFiles(_:fromInbox:)` / `performAdd`, `canAdd`, `selectedLibrary`, `displayName(of:)`, `libraryDidLoad()`, `start()`, `editMessage` (read their current code in `App/AppModel.swift`).
- Produces: `AppModel.receiveHandOver(_ urls: [URL])`; launch argument `-DossiaryHandOver <path>` (DEBUG only) that feeds the same function once at the end of `start()`.

- [ ] **Step 1: Spike — does the open event reach the app without declared document types?**

Add the delegate (Step 3's code) with a TEMPORARY line in `application(_:open:)` that appends the received URLs to `/tmp/claude-501/handover-spike.log`. Build the app (`xcodebuild -project Dossiary.xcodeproj -scheme <scheme from project.yml> -destination 'platform=macOS' -derivedDataPath /tmp/claude-501/handover-dd build`), create `/tmp/claude-501/spike.pdf` (any valid PDF), quit any running Dossiary, then run `open -a /tmp/claude-501/handover-dd/Build/Products/Debug/Dossiary.app /tmp/claude-501/spike.pdf` while the app is closed, and once more while it is running. Check: (a) the log lists the file both times; (b) the number of Dossiary windows did not grow (`osascript -e 'tell application "System Events" to count windows of process "Dossiary"'` before/after the second run); (c) record whether macOS showed any dialog. If (a) fails, add `CFBundleDocumentTypes` for `com.adobe.pdf` and `public.image` as role Viewer with `LSHandlerRank` `None` through `project.yml` (`info:` properties) and retest; if (b) fails (a new window per event), add `.handlesExternalEvents(matching: [])`/`NSApp` handling to prevent new windows and retest. Remove the temporary logging afterwards; put the result (what was needed) in your report and in the commit message.

- [ ] **Step 2: Write the failing UI test** — `testHandedOverFileIsAddedToTheOpenLibrary` in `UITests/DossiaryMacUITests.swift`, using `launchOnACopy(extraArguments: ["-DossiaryHandOver", <pdf path>])` (the PDF with a text layer created in the test like `testInboxBannerAddsTheWaitingFile` does, in a temp folder outside the library): assert the Review queue is shown, a table row titled with the PDF's name stem exists, the result text contains "Added to" and the library's name, and the PDF still exists at its path afterwards. Run it first; expected FAIL.

- [ ] **Step 3: Implement**

`App/DossiaryAppDelegate.swift`:

```swift
import AppKit

/// Receives the system's open-documents event (the Scan Helper opens a scan with this app). Events that arrive before the model is
/// attached (the app was launched by the hand-over) are kept and delivered on `attach`.
final class DossiaryAppDelegate: NSObject, NSApplicationDelegate {
    private var handler: (([URL]) -> Void)?
    private var early: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler { handler(urls) } else { early += urls }
    }

    func attach(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        if !early.isEmpty { let urls = early; early = []; handler(urls) }
    }
}
```

`DossiaryMacApp`: `@NSApplicationDelegateAdaptor(DossiaryAppDelegate.self) private var delegate`; in the existing `.task { … }` call `delegate.attach { model.receiveHandOver($0) }` BEFORE `await model.start()`.

`AppModel`:
- `private var handOverQueue = HandOverQueue()` and `private var started = false` (set true at the end of `start()`).
- `func receiveHandOver(_ urls: [URL])`: `handOverQueue.receive(urls)`; if `started && selectedLibrary == nil` (nothing to add to, none will open by itself) → show an `NSAlert` (informational, text `Open a library to add the scan. It is saved in your scan folder.`) and drop the queue; else `drainHandOver()`.
- `private func drainHandOver()`: `guard !handOverQueue.isEmpty, canAdd, let ref = selectedLibrary`; `let files = handOverQueue.takeAll()`; call the existing add path with `fromInbox: false` and a new parameter `announceLibrary: displayName(of: ref)` that makes `performAdd` put the line `Added to “%@”.` (new key, 7 languages) FIRST in `editMessage` (before the usual summary lines); the files are never removed (they are not Inbox files).
- Call `drainHandOver()` at the end of `libraryDidLoad()` (so files wait for the first library and for a busy add to finish) and at the end of `start()` (after setting `started = true`; if `handOverQueue` is not empty and `selectedLibrary == nil` then, show the alert as above and clear).
- DEBUG only: at the end of `start()`, before the drain, if `UserDefaults.standard.string(forKey: "DossiaryHandOver")` is set, `receiveHandOver([URL(fileURLWithPath: …)])` (wrap in `#if DEBUG`).
- Texts via `scripts/make_strings.py` (NEW dict + KEYS), regenerate: `Added to “%@”.`, `Open a library to add the scan. It is saved in your scan folder.` — all seven languages; keep placeholders identical; the printed list of new English texts goes in your report.

- [ ] **Step 4: Run the new UI test** (expected PASS), then `cd MacCore && swift test` (all pass) and the app's full UI suite once (generous timeout, 10 minutes; one unrelated flaky test `testCollapsingViewsKeepsOnlyTheSelectedView` is known: re-run it alone before judging).

- [ ] **Step 5: With your own eyes** — build, install nothing; run the built app against a library copy, then from a terminal `open -a <built app> /tmp/claude-501/spike.pdf` (a PDF with text) and take a screenshot (`screencapture -x` / cmux-cua) of the Review queue with the result line; look at it and describe it in the report; say so plainly if you could not.

- [ ] **Step 6: Version and docs** — `project.yml` 0.5.1 / 18, `xcodegen generate`; `AGENTS.md` bullet (DossiaryAppDelegate, `HandOverQueue`, `-DossiaryHandOver`, the UI test name, the spike's finding); `README.md`: one sentence that the Scan Helper can hand scans over; `docs/parity-checklist.md` row "Scanning" stays `open` with a note column text "profiles of the Scan Helper can send scans to the app (0.5.1)".

- [ ] **Step 7: Commit** (`dossiary-osx`)

```bash
git add App UITests scripts MacCore project.yml Dossiary.xcodeproj AGENTS.md README.md docs
git commit -m "feat(mac): receive scans handed over by the Scan Helper and add them to the open library (0.5.1)"
```

---

### Task 3: Helper — profile switch, hand-over logic, texts (HelperCore)

**Repo:** `dossiary-scan-helper` (work in `macos/`)

**Files:**
- Modify: `Sources/HelperCore/ScanProfile.swift`, `Sources/HelperCore/ProfileScanRunner.swift`, `Sources/HelperCore/Texts.swift`, `Localization/Localizable.xcstrings`
- Test: `Tests/HelperCoreTests/ProfileScanRunnerTests.swift` (extend), `Tests/HelperCoreTests/ScanProfileStoreTests.swift` or `ScanProfileRulesTests.swift` (extend), the Texts test file that covers `profileScanSummary` (find with `grep -rn profileScanSummary Tests`)

**Interfaces:**
- Produces:
  - `ScanProfile.sendToDossiary: Bool` (init parameter `sendToDossiary: Bool = false` as the last parameter; JSON key `sendToDossiary`, optional when decoding).
  - `public enum HandOverResult: Equatable, Sendable { case sent, notInstalled, failed(String) }`
  - `public struct ProfileScanResult: Equatable, Sendable { public let outcome: ProfileScanOutcome; public let handOver: HandOverResult? }`
  - `ProfileScanRunner.runAndHandOver(_ profile: ScanProfile, handOver: @Sendable ([URL]) async -> HandOverResult) async -> ProfileScanResult`
  - `Texts.profileScanSummary(_ result: ProfileScanResult) -> (title: String, body: String)` (the existing outcome version stays).

- [ ] **Step 1: Write the failing tests**

- `ScanProfile`: JSON without the `sendToDossiary` key decodes with `false`; a profile with `true` round-trips through `JSONEncoder`/`JSONDecoder`; `ScanProfileRules.normalized` keeps `sendToDossiary` for a scanner it changes other fields for.
- `ProfileScanRunnerTests` (use the existing fake-scanner helpers in that file): with the switch ON and a successful scan the closure receives exactly the saved file URLs and the result is `.sent`; with the switch OFF the closure is never called and `handOver == nil`; a failed scan (`.problem`/`.failed`) never calls it; `.partial` hands over only the saved files; `.notInstalled` and `.failed("x")` are passed through while `outcome` stays `.saved`; two files (feeder scan, several files) are handed over in one call.
- Texts test: `profileScanSummary(.init(outcome: .saved(...), handOver: .sent))` body ends with " — Sent to Dossiary." in English, `.notInstalled` gives " — Dossiary for Mac isn't installed. The scan is saved in the folder.", `.failed("boom")` gives " — Couldn't send it to Dossiary: boom"; `handOver: nil` equals the old summary. Plus the localization unittest (below).

- [ ] **Step 2: Run to see failures** — `cd macos && swift test --filter 'ProfileScanRunnerTests|ScanProfile' 2>&1 | tail -20`.

- [ ] **Step 3: Implement**

`ScanProfile`: add `public var sendToDossiary: Bool`; add the init parameter; add explicit coding so old files load:

```swift
    enum CodingKeys: String, CodingKey {
        case id, name, scannerID, scannerName, destination, source, duplex, colorMode, resolution, format, area, ocr, ocrLanguages, sendToDossiary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        scannerID = try c.decode(String.self, forKey: .scannerID)
        scannerName = try c.decode(String.self, forKey: .scannerName)
        destination = try c.decode(String.self, forKey: .destination)
        source = try c.decode(Source.self, forKey: .source)
        duplex = try c.decode(Bool.self, forKey: .duplex)
        colorMode = try c.decode(ColorMode.self, forKey: .colorMode)
        resolution = try c.decode(Int.self, forKey: .resolution)
        format = try c.decode(String.self, forKey: .format)
        area = try c.decodeIfPresent(String.self, forKey: .area)
        ocr = try c.decode(Bool.self, forKey: .ocr)
        ocrLanguages = try c.decode([String].self, forKey: .ocrLanguages)
        sendToDossiary = try c.decodeIfPresent(Bool.self, forKey: .sendToDossiary) ?? false
    }
```

`ProfileScanRunner` (add near the types at the top and the method inside the class):

```swift
public enum HandOverResult: Equatable, Sendable {
    case sent, notInstalled, failed(String)
}

/// A profile scan and, when the profile asked for it, what happened when the saved files were handed to Dossiary.
public struct ProfileScanResult: Equatable, Sendable {
    public let outcome: ProfileScanOutcome
    public let handOver: HandOverResult?
    public init(outcome: ProfileScanOutcome, handOver: HandOverResult?) { self.outcome = outcome; self.handOver = handOver }
}
```

```swift
    /// `run`, then (only for a profile with `sendToDossiary`, and only when files were saved) hands the saved files over.
    /// A failed hand-over never changes the outcome: the scan is saved either way.
    public func runAndHandOver(_ profile: ScanProfile,
                               handOver: @Sendable ([URL]) async -> HandOverResult) async -> ProfileScanResult {
        let outcome = await run(profile)
        guard profile.sendToDossiary else { return ProfileScanResult(outcome: outcome, handOver: nil) }
        switch outcome {
        case .saved(let files, _, _), .partial(let files, _):
            return ProfileScanResult(outcome: outcome, handOver: await handOver(files))
        case .failed, .problem:
            return ProfileScanResult(outcome: outcome, handOver: nil)
        }
    }
```

`Texts`: next to `profileScanSummary(_ outcome:)` add

```swift
    /// The notification for a profile scan that may also have been handed to Dossiary.
    public func profileScanSummary(_ result: ProfileScanResult) -> (title: String, body: String) {
        let t = self
        let base = profileScanSummary(result.outcome)
        switch result.handOver {
        case nil: return base
        case .sent?: return (base.title, base.body + " — " + t("Sent to Dossiary."))
        case .notInstalled?: return (base.title, base.body + " — " + t("Dossiary for Mac isn't installed. The scan is saved in the folder."))
        case .failed(let message)?: return (base.title, base.body + " — " + t("Couldn't send it to Dossiary: %@", message))
        }
    }
```
(Use the same `t(...)` call style the neighbouring code uses for texts with arguments.)

Texts in `Localization/Localizable.xcstrings`, all seven languages, placeholders identical: `Sent to Dossiary.`, `Dossiary for Mac isn't installed. The scan is saved in the folder.`, `Couldn't send it to Dossiary: %@`, `Also send to Dossiary` (the form label, Task 4 uses it with a literal `L("Also send to Dossiary")`). Add them by editing the JSON with a script that preserves the file's formatting and key order (insert, do not re-sort the file; check `git diff --stat` is only the new keys), then run the localization checks: `python3 -m unittest discover -s scripts -p 'test_*.py'` from `macos/`.

- [ ] **Step 4: Run all tests** — `cd macos && swift test 2>&1 | tail -6` and the localization unittests; all pass.

- [ ] **Step 5: Commit** (`dossiary-scan-helper`)

```bash
git add macos
git commit -m "feat(macos): scan profiles can hand their scan to Dossiary (logic and texts)"
```

---

### Task 4: Helper — the app side: hand-over, form switch, notification, docs, version

**Repo:** `dossiary-scan-helper` (work in `macos/`)

**Files:**
- Create: `Sources/App/DossiaryHandOver.swift`
- Modify: `Sources/App/AppDelegate.swift`, `Sources/App/ProfileFormPanel.swift`, `Sources/HelperCore/Version.swift` (0.8.0), `AGENTS.md`, `macos/README.md`, `docs/manual-check-macos.md`

**Interfaces:**
- Consumes: `ProfileScanRunner.runAndHandOver`, `ProfileScanResult`, `HandOverResult`, `Texts.profileScanSummary(_ result:)`, `ScanProfile.sendToDossiary` (Task 3).

- [ ] **Step 1: `DossiaryHandOver`**

```swift
import AppKit
import HelperCore

/// Hands saved scans to Dossiary for Mac with the system's open-documents event. No custom URL scheme: a web page could trigger one.
enum DossiaryHandOver {
    static let bundleID = "com.aarneaarebye.dossiary-mac"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var isInstalled: Bool { appURL != nil }

    static func send(_ files: [URL]) async -> HandOverResult {
        guard let app = appURL else { return .notInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false      // the helper does not steal the focus
        do {
            _ = try await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration)
            return .sent
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Wire the run** — in `AppDelegate`, replace `await runtime.profileRunner.run(profile)` with `await runtime.profileRunner.runAndHandOver(profile) { await DossiaryHandOver.send($0) }`; change `profileScanFinished` to take the `ProfileScanResult` (state updates use `result.outcome` exactly as before; the notification uses `L.profileScanSummary(result)`). A hand-over `.notInstalled` or `.failed` does not set `profileProblem` (the scan is fine); it only shows in the notification.

- [ ] **Step 3: The form** — in `ProfileFormPanel` add `private let dossiaryBox = NSButton(checkboxWithTitle: L("Also send to Dossiary"), target: nil, action: nil)`, a grid row under the folder row (label cell empty, like the OCR row), shown only when `DossiaryHandOver.isInstalled || draft.sendToDossiary` (a profile that already has it on keeps showing it), `readControls()` writes `draft.sendToDossiary`, `reload()` sets the state; use the same target/action as the other boxes and the container/fit logic already in the panel so the window still fits. A new profile starts with the switch off.

- [ ] **Step 4: Tests and checks** — HelperCore has no new logic here. Run `swift test` and the localization unittests (the new label key must be found: it is a literal `L("…")`). Build and run the app (`scripts/build-app.sh`, `scripts/install-app.sh` is NOT part of this task — do not install). Open the profile form with the built app if you can drive it (cmux-cua) and look at the form with the switch; otherwise say plainly that you did not see it.

- [ ] **Step 5: Docs and version** — `Version.swift` 0.8.0; `AGENTS.md` bullet (`sendToDossiary`, `runAndHandOver`, `DossiaryHandOver`, the open-documents event and why no URL scheme); `macos/README.md` section on "Also send to Dossiary"; `docs/manual-check-macos.md` a "Scan to Dossiary (0.8.0)" checklist: switch on, scan with the Mac app closed (it starts, adds the scan to its last library), with it open on another library, with no library open (the app says so and the scan stays in the folder), with Dossiary not installed (notification says so), partial scan, and "the folder copy always exists".

- [ ] **Step 6: Commit** (`dossiary-scan-helper`)

```bash
git add macos docs AGENTS.md
git commit -m "feat(macos): Also send to Dossiary on scan profiles (0.8.0)"
```

Do not tag, push, notarize or release; report that helper 0.8.0 is committed.
