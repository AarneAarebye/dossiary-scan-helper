# Scan profiles in the Dossiary Scan Helper's menu — design

Date: 2026-11-11. Helper version 0.7.0. Status: approved in conversation (the user chose "B with scan
profiles for the pi scanners" and "a form in the helper").

## Why

Scanning over a Raspberry Pi works from Dossiary: the helper lists the Pi's scanners as
`remote:<server>:<id>` and forwards `POST /scan`. Neither menu bar app can start such a scan itself. The
helper's menu has no scan action at all, and the scanix500 menu bar app has no network client. The helper
already holds the pairing, the pinned certificate and the tokens, so the helper's menu is the place to add it.

## What it does

- The helper's menu lists **scan profiles**. Clicking one scans with that profile and saves the file in the
  profile's folder.
- A profile is: name, scanner, folder, source (flatbed or feeder), duplex, color mode, resolution, format
  (PDF, JPEG, PNG), paper size (area), OCR on/off and OCR languages.
- "Scan profiles…" opens a window with New…, Edit…, Delete. The form offers only what the chosen scanner can do.
- Any scanner the helper lists can be used: the Pi's and the Mac's own (the helper already merges both lists).

## How it works

1. **One scan path.** `Router` gets `performScan(_ body: Any)` and `performOCR(_ id: String)`, the bodies of
   its `/scan` and `/ocr/<job>` routes without HTTP. The HTTP routes call them, and so does the profile runner.
   A profile scan therefore gets the same validation, the same 409 "another scan is running", the same local or
   network dispatch and the same OCR jobs as a scan from Dossiary. `PROTOCOL.md` does not change.
2. **Profiles.** `ScanProfile` (Codable) lives in `profiles.json` in `~/Library/Application Support/dossiary-scan-helper/`
   (`ScanProfileStore`). `ScanProfileRules` computes what the form offers for a scanner and source/color
   (duplex only from a duplex feeder, images only from the flatbed, no JPEG in black and white, OCR only for PDF),
   normalizes a profile to a scanner, and builds the `/scan` request body.
3. **Running.** `ProfileScanRunner.run(profile)` finds the scanner, calls `router.performScan`, and for each file
   waits for its OCR job (poll every 2 s, give up after 10 minutes, then keep the plain scan), then saves it with
   `ButtonScanFolder.save(…, into:)` as `scan_YYYY-MM-DD_HHMMSS.<ext>` (never overwrites; `_1`, `_2` for several
   files). Only one profile scan runs at a time.
4. **Feedback.** The menu entry of the running profile reads "Scanning “name”…" and the entries are disabled.
   A notification says "N pages scanned" with the file name, "Scan incomplete" (partial) or "Scan failed" with the
   server's message. The menu keeps "Last profile scan: <file>".
5. **Texts.** New texts go through `Texts` and are translated in all seven languages. Messages from the
   scanner or server are shown as they come, like pairing refusals.

## Not in this version

- Collecting several flatbed pages into one PDF from the menu (the Pi's buttons do that).
- Profiles in the scanix500 Python menu bar app (unchanged).
- Keyboard shortcuts, scheduled scans, per-profile sounds.

## Failure behaviour

- Scanner off or server unreachable: failure notification with the reason; nothing is saved.
- Another scan running (Dossiary or a second profile): "Another scan is still running."
- OCR not finished within 10 minutes or failed: the plain scan is saved and the notification says so.
- Folder not writable: the system's reason is shown.
- A profile whose scanner is currently missing can still be edited (name and folder); its other choices stay.
- An unreadable `profiles.json` is moved aside as `profiles.json.unreadable`; the helper starts with no profiles.
