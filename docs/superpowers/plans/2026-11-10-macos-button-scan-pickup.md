# macOS helper 0.6.0: pick up button scans from a network scan server

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS helper fetches PDFs that a paired `scanix500-server` (0.10.0+) made from the CanoScan 8800F's buttons, saves each one into a folder chosen in the helper's menu (default `~/Documents/Scans`), and only then deletes it on the server.

**Architecture:** A testable `ButtonScanPickup` in `HelperCore` polls each paired server every 5 s through the existing `RemoteTransport` (list, download, delete), writes files with a `ButtonScanFolder`, and remembers what it saved in a `PickedUpLedger` so a retry or a second pass never saves twice. The app target only adds a menu item, a folder chooser and a notification.

**Tech Stack:** Swift (SwiftPM, macOS 14+, Command Line Tools, no Xcode), XCTest, Foundation, UserNotifications, AppKit (App target only).

Spec: `/Users/aarneaarebye/Projects/Paperless/iX500/docs/superpowers/specs/2026-11-10-pi-button-scans-design.md` ("macOS helper", "Protocol"); the server side is done in scanix500 0.10.0 (iX500 repo, plan `docs/superpowers/plans/2026-11-10-pi-button-scans.md`). Repo: `/Users/aarneaarebye/Projects/Paperless/dossiary-scan-helper`; the Swift package is in `macos/`.

## Global Constraints

- Server protocol (already implemented in scanix500 0.10.0; the helper only consumes it), remote servers only, every request with `Authorization: Bearer <token>` (the helper's existing `RemoteRequest.token`): `GET /health` has `"buttonScans": true` when the server offers it; `GET /button-scans` -> `200 {"scans":[{"id","name","pages","bytes","created","ocr"}]}` oldest first, `ocr` is `"pending"`, `"done"` or `"failed"`; `GET /button-scans/<id>` -> `200` the PDF bytes (`application/pdf`; header `X-Scanix500-Ocr: pending` while text recognition is not done; the helper uses the list's `ocr` field instead of the header); `DELETE /button-scans/<id>` -> `204` (or `404` when already gone: also success). `401` means the token is no longer valid. Ids match `\A[A-Za-z0-9_-]{22,}\Z`; the helper must not build a request path from an id that does not match.
- Pickup rules: take a scan when `ocr` is `done` or `failed`, or `pending` for more than 30 minutes (raised from 5 after the final review) after the helper first saw it. Save order: download, check the body starts with `%PDF-` and `body.count == bytes` from the list, write the file (atomically: temp file in the same folder, then rename), record the id in the ledger, and only then `DELETE`. A failed save or failed delete never loses a scan: the scan stays on the server and is tried again on a later pass; an id already in the ledger is not saved again, only deleted.
- Never talk to a server that did not say `buttonScans` in `/health`, a server that is unreachable, has no token (`needsPairing`) or a changed certificate: skip it silently this pass (the existing `RemoteStatus` logic and log lines already report those).
- File names: the list's `name` (`scan_YYYY-MM-DD_HHMMSS.pdf`), made safe (only the last path component, no `/`, no leading `.`, `.pdf` suffix guaranteed); an existing file of that name is never overwritten: ` 2`, ` 3`, … is appended before the extension.
- Folder: remembered in `UserDefaults` (key `buttonScanFolder`, a path); default `~/Documents/Scans`; created when missing; when it cannot be written, PDFs stay on the server and the menu shows "Button scans can't be saved: <reason>".
- Nothing but the three calls and `/health` is sent to the server. No new third-party dependency. Messages sent to Dossiary stay English (this feature sends none); everything a person sees goes through `Texts`/`Localizable.xcstrings` in all seven languages (en, de, es, fr, zh-Hans, zh-Hant, hy), key = English text; the localization tests fail on missing translations. The new English texts are listed in the final report for the user's Grammarly check.
- Run `macos/scripts/test.sh` (unit tests) and `python3 -m unittest discover -s scripts -p 'test_*.py'` (from `macos/`, localization tests) before each commit that touches code. Do not edit `HelperVersion.string`, tags or release files: the controller does the 0.6.0 release.
- This plan has no conformance-suite task: that suite tests a helper's localhost API over HTTP (`SCAN_HELPER_URL`), while the new calls are between the helper and a scan server and are tested in the iX500 repo (`tests/server/test_button_scan_endpoints.py`) and here with a stub transport.

---

### Task 1: Protocol text and docs

**Files:**
- Modify: `PROTOCOL.md` (section "Network scan servers (scanix500-server)")
- Modify: `docs/install-macos.md` (one paragraph), `macos/README.md` (a short "Button scans" subsection), `AGENTS.md` (one bullet under Conventions)

- [ ] **Step 1: PROTOCOL.md.** After the paragraph on button pairing in "Network scan servers", add a subsection "Button scans" stating exactly the calls in Global Constraints (what each returns, the `ocr` values, ids, `401`, `404`, `DELETE` after a successful save, oldest first, files kept by the server until deleted or 30 days) and `GET /health` adding `"buttonScans": true`. State that these calls are between a helper and a server, not part of the localhost API that Dossiary uses, and that a helper which does not implement them keeps working (the PDFs wait on the server). One short sequence diagram in text (list, download, save, delete).
- [ ] **Step 2: Docs.** `docs/install-macos.md` and `macos/README.md`: a button scan made on a Pi arrives in the helper's button-scan folder (menu "Folder for button scans…", default `~/Documents/Scans`); point it at a library's Inbox so Dossiary imports it; the helper needs 0.6.0 and a server with scanix500 0.10.0; PDFs wait on the server while the helper is off. `AGENTS.md`: one bullet: "Button scans (0.6.0): `ButtonScanPickup` fetches PDFs from paired scan servers (`GET/DELETE /button-scans…`), deletes on the server only after the file is saved; ledger `picked-up.json`; folder setting `buttonScanFolder`."
- [ ] **Step 3: Commit** `git add PROTOCOL.md docs macos/README.md AGENTS.md && git commit -m "docs: protocol text for button scans on a network scan server"` (end the message with the attribution lines the session requires).

---

### Task 2: `ButtonScanFolder` and `PickedUpLedger`

**Files:**
- Create: `macos/Sources/HelperCore/ButtonScanFolder.swift`, `macos/Sources/HelperCore/PickedUpLedger.swift`
- Create: `macos/Tests/HelperCoreTests/ButtonScanFolderTests.swift`, `macos/Tests/HelperCoreTests/PickedUpLedgerTests.swift`

**Interfaces:**
- Produces (Tasks 3 and 4 use exactly these):
  ```swift
  public final class ButtonScanFolder: @unchecked Sendable {
      public static var defaultURL: URL                 // ~/Documents/Scans
      public init(defaults: UserDefaults = .standard, key: String = "buttonScanFolder", fallback: URL = ButtonScanFolder.defaultURL)
      public var url: URL { get }                       // the chosen folder or the fallback
      public func choose(_ url: URL)                    // remembers the path
      /// Writes `data` as a new file named after `name` in the folder and returns its URL; never overwrites.
      public func save(_ data: Data, named name: String) throws -> URL
      /// Pure: the safe file name for a server-supplied name.
      public static func safeName(_ name: String) -> String
  }
  public struct ButtonScanSaveError: Error, Equatable, Sendable { public let reason: String }

  public final class PickedUpLedger: @unchecked Sendable {
      public static var defaultFileURL: URL             // Application Support/dossiary-scan-helper/picked-up.json
      public init(fileURL: URL?, clock: @escaping @Sendable () -> Date = Date.init, retention: TimeInterval = 30 * 24 * 3600)
      public func contains(_ id: String) -> Bool
      public func record(_ id: String, file: String) throws   // atomic write; also prunes entries older than retention
  }
  ```

- [ ] **Step 1: Failing tests.** `safeName`: keeps `scan_2026-11-10_151030.pdf`; strips directories (`../../x.pdf` -> `x.pdf`), a leading `.` (`.hidden.pdf` -> `hidden.pdf`), NUL/control characters, appends `.pdf` when missing, replaces an empty result with `scan.pdf`, limits the length to 120 characters keeping the suffix. `save`: writes the bytes; a second save of the same name gives `name 2.pdf`, then `name 3.pdf`; the first file is never touched; creates the folder when missing; the write is atomic (no half file visible: assert no `.tmp` leftover and that a failure, simulated with a read-only folder, throws `ButtonScanSaveError` with a readable reason and leaves nothing behind); `url` returns the fallback until `choose`, then the chosen path, which survives a new instance on the same `UserDefaults` suite (use `UserDefaults(suiteName:)` with a unique name per test). Ledger: `record` then `contains`; a new instance on the same file still contains it; entries older than `retention` (fake clock) are pruned on the next `record`; a missing or damaged file means empty (a damaged file is not an error); `fileURL: nil` keeps it in memory.
- [ ] **Step 2: Run** `cd macos && scripts/test.sh`. Expected: FAIL (types missing).
- [ ] **Step 3: Implement.** `save`: pick a free name by checking `FileManager.fileExists` in a loop with the ` 2`, ` 3` suffix, write to `<free>.<random>.tmp` in the same folder, `moveItem`/`replaceItemAt` to the final name only if it still does not exist (use `FileManager.moveItem`, which fails if the destination exists), clean up the temp on any error. Ledger JSON: `{"<id>": {"file": "...", "saved": <seconds since 1970>}}`, written atomically like `RemoteServerStore.save`.
- [ ] **Step 4: Run** the new tests then the whole suite. Expected: all pass.
- [ ] **Step 5: Commit** `git add macos && git commit -m "feat: button scan folder and picked-up ledger"` (with the attribution lines).

---

### Task 3: `ButtonScanPickup`

**Files:**
- Create: `macos/Sources/HelperCore/ButtonScanPickup.swift`
- Modify: `macos/Tests/HelperCoreTests/RemoteTestSupport.swift` (a binary-body variant of `FakeTransport`)
- Create: `macos/Tests/HelperCoreTests/ButtonScanPickupTests.swift`

**Interfaces:**
- Consumes: `RemoteServerStore` (`servers`, `token(for:)`), `RemoteTransport`/`RemoteRequest`/`RemoteReply`, `RemoteError`, `RemoteScanners.TransportFactory`, `ButtonScanFolder`, `PickedUpLedger`.
- Produces:
  ```swift
  public struct PickedUpScan: Equatable, Sendable { public let name: String; public let file: URL; public let pages: Int; public let server: String }

  public final class ButtonScanPickup: @unchecked Sendable {
      public init(store: RemoteServerStore, folder: ButtonScanFolder, ledger: PickedUpLedger,
                  transport: @escaping RemoteScanners.TransportFactory = { URLSessionRemoteTransport(host: $0.host, port: $0.port, pin: $0.fingerprint) },
                  clock: @escaping @Sendable () -> Date = Date.init,
                  onPickedUp: @escaping @Sendable (PickedUpScan) -> Void = { _ in },
                  log: @escaping @Sendable (String) -> Void = { _ in })
      /// One pass over every paired server. Never throws; problems are logged and kept in `lastProblem`.
      public func pickUpOnce() async
      public func start(interval: TimeInterval = 5)    // a Task that calls pickUpOnce, sleeps, repeats until stop()
      public func stop()
      public var lastProblem: String? { get }          // e.g. "Button scans can't be saved: <reason>"; nil after a clean pass
      public var lastScan: PickedUpScan? { get }
  }
  ```
  `FakeTransport` (existing) answers JSON only. Add a second initialiser or a sibling `FakeBinaryTransport` whose handler returns `(status, Data)` so a test can serve `GET /button-scans/<id>` as PDF bytes; keep the existing tests untouched.

- [ ] **Step 1: Failing tests** (stub transport scripted per path; in-memory ledger; folder in a temp dir; fake clock; `PickedUpScan` captured through `onPickedUp`):
  1. a server whose `/health` says `buttonScans: true` and lists one `done` scan: the file is downloaded, written into the folder with the listed name, recorded in the ledger, then `DELETE` is sent (assert the request order: `/health`, list, `GET /button-scans/<id>`, `DELETE`), `onPickedUp` fires once, `lastScan` is set;
  2. `/health` without `buttonScans` (or false): only `/health` is requested;
  3. unreachable server (transport throws `RemoteError.unreachable`), a `401` on the list, a certificate change, no token: nothing saved, no crash, other servers still served (two servers in one pass);
  4. a `pending` scan is not taken until the fake clock is more than 30 minutes (raised from 5 after the final review) after the first pass that saw it, then it is; `failed` is taken at once;
  5. body not starting with `%PDF-` or with a size different from `bytes`: not saved, not deleted, logged, retried on the next pass; an id not matching `\A[A-Za-z0-9_-]{22,}\Z` is skipped without any request containing it;
  6. the save fails (folder unwritable): no `DELETE`, `lastProblem` starts with "Button scans can't be saved", the next pass with a writable folder saves and clears `lastProblem`;
  7. the `DELETE` fails (network error or 500) after a successful save: the ledger holds the id, the next pass does NOT save again but sends `DELETE` again; `404` from DELETE counts as success;
  8. an id already in the ledger and still listed: not downloaded again, only deleted;
  9. two scans in one list are taken oldest first, each with its own file; a name clash with an existing file gets ` 2`;
  10. `start`/`stop`: with a short interval the loop runs several passes and `stop()` ends it (use an expectation with a counting transport); a pass in progress is not started twice (a second `pickUpOnce` called concurrently returns without work).
- [ ] **Step 2: Run** `cd macos && scripts/test.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.** One `NSLock`-guarded `running` flag so passes never overlap; `firstSeen: [String: Date]` for the 5-minute rule (in memory; a restart starts the clock again, which is fine); validate ids with a regex before building a path; sizes and `%PDF-` check as in Global Constraints; the server's display name in `PickedUpScan.server`; log lines in English through `log` (no file names of documents' contents; the names are `scan_<timestamp>.pdf`).
- [ ] **Step 4: Run** the new tests then the whole suite. Expected: all pass.
- [ ] **Step 5: Commit** `git add macos && git commit -m "feat: ButtonScanPickup fetches button scans from paired scan servers"` (with the attribution lines).

---

### Task 4: Menu, runtime and notification

**Files:**
- Modify: `macos/Sources/HelperCore/MenuModel.swift` (`MenuAction.chooseButtonScanFolder`; entries), `macos/Sources/HelperCore/HelperRuntime.swift` (create and own the pickup when `remote != nil`; start in `start()`, stop in `stop()`)
- Modify: `macos/Sources/App/AppDelegate.swift` (the new action: `NSOpenPanel` folder chooser; notification), create `macos/Sources/App/PickupNotifier.swift` (UserNotifications)
- Modify: `macos/Tests/HelperCoreTests/MenuModelTests.swift`

**Interfaces:**
- Consumes: `ButtonScanPickup` (Task 3), `ButtonScanFolder`, `PickedUpLedger`.
- `MenuModel.entries(...)` gets two new optional parameters, defaulted so existing callers and tests compile: `buttonScanFolder: String? = nil` (the folder's display name, shown only when `networkServers != nil`) and `lastButtonScan: String? = nil`, `buttonScanProblem: String? = nil`. When `networkServers` is present the menu shows, after "Add network scanner…": `.info("Button scans go to “%@”")` with the folder's last path component, `.action("Folder for button scans…", .chooseButtonScanFolder, …)`, then `.info("Last button scan: %@")` when `lastButtonScan` is set and `.info(problem)` when `buttonScanProblem` is set. No entry at all in fake mode (`networkServers == nil`).
- `HelperRuntime` exposes `public let buttonScanFolder: ButtonScanFolder?` and `public let buttonScanPickup: ButtonScanPickup?` (nil when `remote == nil`, i.e. in fake mode).

- [ ] **Step 1: Failing tests** in `MenuModelTests.swift`: with network servers the new entries appear in that order with the folder name; `lastButtonScan` and `buttonScanProblem` add their info lines; with `networkServers == nil` none of them appears; existing tests unchanged.
- [ ] **Step 2: Run** the tests. Expected: FAIL.
- [ ] **Step 3: Implement.** `HelperRuntime`: build `ButtonScanFolder()`, `PickedUpLedger(fileURL: PickedUpLedger.defaultFileURL)` and `ButtonScanPickup(store:folder:ledger:log:onPickedUp:)` next to `remote`; `onPickedUp` is a closure property the app sets (so the notifier lives in the App target); `start()` starts the pickup loop after the HTTP server is up, `stop()` stops it. `AppDelegate`: pass `folder.url.lastPathComponent`, `pickup.lastScan?.name` and `pickup.lastProblem` to `MenuModel.entries`; `.chooseButtonScanFolder` opens an `NSOpenPanel` (directories only, can create directories, prompt "Choose") and calls `folder.choose(url)`; `PickupNotifier` uses `UNUserNotificationCenter`: requests authorisation lazily at the first picked-up scan, shows "N pages scanned" with the file name in the body (texts via `L`), and does nothing when permission is refused (the menu line remains the record). Menu rebuilds already happen in `menuNeedsUpdate`.
- [ ] **Step 4: Run** `scripts/test.sh` and `swift build` (the App target must compile). Expected: all pass, build succeeds. Launch is not needed.
- [ ] **Step 5: Commit** `git add macos && git commit -m "feat: menu item and notification for button scans"` (with the attribution lines).

---

### Task 5: Seven languages and docs check

**Files:**
- Modify: `macos/Localization/Localizable.xcstrings`

- [ ] **Step 1:** Add every new user-visible text from Task 4 to `Localizable.xcstrings` with all seven languages (en = the key; de, es, fr, zh-Hans, zh-Hant, hy). Keys (use these exact English texts; `%@`/`%lld` placeholders must be kept in every translation): `Button scans go to “%@”`, `Folder for button scans…`, `Last button scan: %@`, `Button scans can't be saved: %@`, `%lld pages scanned`, `Choose`, and the notification title if a distinct one was used. Armenian is not reviewed by a person.
- [ ] **Step 2: Run** `cd macos && python3 -m unittest discover -s scripts -p 'test_*.py'` and `scripts/test.sh`. Expected: all pass (the localization tests fail on a missing translation, a changed placeholder or an unused key; fix the catalogue until they pass, never the tests).
- [ ] **Step 3:** In the report, list the new English texts for the user's Grammarly check.
- [ ] **Step 4: Commit** `git add macos && git commit -m "feat: translations for button scans"` (with the attribution lines).
