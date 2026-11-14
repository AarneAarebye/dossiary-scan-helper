# Scan to Dossiary — design

Date: 2026-11-14. Versions: Dossiary Scan Helper 0.8.0 and Dossiary for Mac 0.5.1. Status: direction approved in conversation
("option 1 first, then option 2"): the helper hands a finished scan to the Mac app, like a ScanSnap Home profile that sends the
scan to an application. Option 2 (a Scan button inside the Mac app that talks to the helper) is a later, separate design and
reuses the adding code of this one.

## Why

The Mac app can add documents (0.5.0: Add Documents…, drops, the `inbox/` banner) but cannot scan. The Scan Helper already scans
with the Mac's own scanners and with the Pi's (profiles, 0.7.x). A scan still ends as a file in a folder, and getting it into a
library is a second step. With a hand-over the profile's one click scans and files the document.

## What it does

- A scan profile gets a switch **Also send to Dossiary** (off by default; shown only when Dossiary for Mac is installed).
- When on, a finished profile scan is saved in the profile's folder as today, and then the saved file(s) are handed to the Mac
  app, which adds them to the library it has open (flagged for review, in the Review queue), exactly like Add Documents.
- The folder stays: it is the scan archive and the fallback. A hand-over that fails never loses a scan.
- The helper's notification says when the scan was sent ("2 pages scanned, sent to Dossiary"); the Mac app's result line names
  the library ("Added to “Walldorf”: 1 document added").

## How it works

**Helper (0.8.0).**
1. `ScanProfile` gets `sendToDossiary: Bool` (optional in JSON, default false, so existing `profiles.json` files load unchanged).
2. `ProfileScanRunner`, after it has saved the files, calls an injected `handOver: ([URL]) async -> HandOverResult` when the
   profile asks for it and the outcome is `.saved` or `.partial` (the files that were saved). `HandOverResult` is `.sent`,
   `.notInstalled`, or `.failed(String)`. The result goes into the outcome and the notification text; it never changes whether
   the scan counts as saved.
3. The real hand-over (`DossiaryHandOver`, App target) finds the app with
   `NSWorkspace.urlForApplication(withBundleIdentifier: "com.aarneaarebye.dossiary-mac")` and calls
   `NSWorkspace.open(_:withApplicationAt:configuration:)` with the file URLs (activates = false, so the helper does not steal
   the focus). It uses the system's open-documents event, **not** a custom URL scheme: a URL scheme such as `dossiary://add` could
   be triggered by any web page and would let it make the app add local files.
4. The form shows the switch under the folder; a profile with the switch on but no Dossiary installed shows the notification
   "Dossiary for Mac isn't installed. The scan is saved in the folder." and keeps its switch.
5. New texts go through `Texts` and are translated in all seven languages.

**Mac app (0.5.1).**
1. The app accepts the open-documents event (`application(_:open:)` through an `NSApplicationDelegateAdaptor`, or SwiftUI
   `onOpenURL`; the plan settles which receives events from `NSWorkspace.open(_:withApplicationAt:)` for a file the app does not
   claim in Info.plist — it must work **without** declaring document types, so Dossiary is not offered as "Open With" for every
   PDF; if that proves impossible, declare PDF and image types as role Viewer with handler rank None).
2. `AppModel.handOver(_ urls: [URL])` keeps only existing, regular files of a type the adder supports (PDF, images) and queues
   them. If no library has loaded yet (the app was just launched), they wait until the first library is open; if the person has no
   library open and none can be restored, the app shows "Open a library to add the scan. It is saved in your scan folder." and
   adds nothing. Otherwise it runs the same path as Add Documents (`addDocuments`: `DocumentIntake` and `DocumentEditor.add`, one
   `EditQueue` ticket, guard 1, Review queue with the new document selected).
3. Files handed over are **never** removed or moved by the app (they are the profile's archive copy, not Inbox files). The same
   scan handed over twice is a duplicate by hash and is reported as such.
4. The result line names the library for a hand-over (`IntakeSummary` gets the library name passed in by the app; text
   `Added to “%@”: %@`-style, final wording in the plan, all seven languages).
5. Identifiers/tests: MacCore tests for the filter and queue rules (`HandOverQueue`: type filter, missing files, waits for a
   library, empty library case); a DEBUG-only launch argument `-DossiaryHandOver <path>` feeds the same code path in a UI test
   (XCUITest cannot send an open-documents event), asserting the document appears in the Review queue and the file is untouched.

## Failure behaviour

- Scan fails: nothing is handed over (as today).
- Save fails or partial: only the files that were saved are handed over.
- Mac app not installed: scan saved, notification says so.
- App not running: it is launched; the files wait for the library to load; if no library is available the app says so.
- Add fails in the app (not a PDF/image, unreadable, no space, library read-only): the app's result line says why; the scan stays in
  the folder.
- Two profile scans in a row: each hand-over is queued behind the earlier one by the app's `EditQueue`.

## Not in this version

- A Scan button in the Mac app (option 2, designed separately; it will reuse `AppModel.addDocuments`).
- Choosing the target library per profile (the app uses the library it has open); a library list in the helper.
- Hand-over of the Pi's hardware-button scans (button-scan pickup) — a natural follow-up that reuses `DossiaryHandOver`.
- Removing the scan from the folder after a successful hand-over.

## Tests and docs

- Helper (`macos/Tests`): `ProfileScanRunnerTests` — hand-over called with exactly the saved files when the switch is on; not
  called when off; not called when the scan failed; `.notInstalled` and `.failed` do not change `.saved`; partial hands over
  only the saved files; `ScanProfile` JSON without the key loads with `false`; `ScanProfileRules.normalized` keeps the switch;
  `Texts` summary text for each hand-over result; localization tests (7 languages).
- Mac app: as under "Mac app" above, plus the full UI suite.
- Docs: `AGENTS.md` bullet, `macos/README.md` section, `docs/manual-check-macos.md` steps (scan with the switch on and the Mac
  app closed, open and with no library), the Mac app's `AGENTS.md`/README line, parity checklist row "Scanning" notes the
  hand-over (the row stays `open` until option 2).
- Releases: helper 0.8.0 (notarized zip, install, pointer) and Mac 0.5.1 (same), in that order or together.
