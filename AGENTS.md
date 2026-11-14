# AGENTS.md

## What this repo is

Helpers that let [Dossiary](https://github.com/AarneAarebye/Dossiary) (a browser app) scan with
scanners the user's computer supports. A helper runs locally on `127.0.0.1:8766` and speaks the
bridge protocol in `PROTOCOL.md`.

| Path | Purpose |
|---|---|
| `PROTOCOL.md` | The protocol every helper implements. The source of truth: change it first, then the helpers. |
| `reference/` | Python helper (`scanbridge_ref`) with fake scanners. Standard library only, Python 3.11+. |
| `conformance/` | Black-box tests of any running helper over HTTP (`SCAN_HELPER_URL`). |
| `macos/` | Swift menu bar helper (SwiftPM, no Xcode needed). Code in `Sources/HelperCore` (testable logic) and `Sources/App` (AppKit UI). |
| `docs/` | Install guide, manual hardware checklist, design plans in `docs/superpowers/plans/`. |

The Windows helper does not exist yet.

## Commands

    # Reference helper
    cd reference && python3 -m unittest discover -s tests -v
    cd reference && python3 -m scanbridge_ref --port 8766

    # Conformance suite against a running helper (pairing code in fake mode is 000000)
    SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v

    # macOS helper (macOS 14+, Command Line Tools)
    cd macos
    scripts/test.sh                  # unit tests
    scripts/run-conformance.sh       # builds, starts with --fake-scanners, runs the suite
    python3 -m unittest discover -s scripts -p 'test_*.py'   # localization script tests
    swift run dossiary-scan-helper --fake-scanners

CI (`.github/workflows/conformance.yml`) runs the reference helper tests and conformance on
Linux, macOS and Windows, and the macOS unit tests, localization tests and conformance on macOS.

## Conventions

- A protocol change touches `PROTOCOL.md`, the reference helper, the conformance tests and the
  macOS helper together. Optional pieces of the protocol (the fake scanners `fake:ocr` and
  `fake:photo`) may lag in the macOS helper, their tests skipping when a helper doesn't list the
  fake scanner; rules that apply to every helper may not lag.
- User-visible text in the macOS app lives in `macos/Localization/Localizable.xcstrings` (the
  English text is the key) and `InfoPlist.xcstrings`. Keep all seven languages complete; the
  localization tests fail on missing translations, changed placeholders or unknown keys. Messages
  sent to Dossiary stay English.
- Release: bump `HelperVersion.string` in `macos/Sources/HelperCore/Version.swift`, then follow
  "Release" in `macos/README.md`. Signing credentials stay in the local keychain, never in the repo.
- `scripts/install-app.sh` installs to `/Applications/Dossiary` and removes the `build/` copy;
  two copies under one bundle id break the "Open at Login" item.
- Button scans (0.6.0): `ButtonScanPickup` fetches PDFs from paired scan servers
  (`GET/DELETE /button-scans…`), deletes on the server only after the file is saved; ledger
  `picked-up.json`; folder setting `buttonScanFolder`.
- Button press sound (0.6.1): `ButtonScanPickup.onButtonPress` plays Tink (color/bw/custom) or Glass
  (finish) via `ButtonPressSound`; menu switch backed by `ButtonPressSetting`; needs scanix500 0.10.1.
- Scan profiles (0.7.0): the menu lists profiles (`ScanProfileStore`, `profiles.json` in Application Support) and "Scan profiles…"
  opens the editor (`ScanProfilesPanel`, `ProfileFormPanel`). `ProfileScanRunner` scans through `Router.performScan`
  (so exactly like a scan from Dossiary), waits for each file's OCR job (give up after 10 minutes, keep the plain scan)
  and saves with `ButtonScanFolder.save(…, into:)`. `ScanProfileRules` is the one place that knows what a scanner offers.
- Scan to Dossiary (0.8.0): `ScanProfile.sendToDossiary` (form switch "Also send to Dossiary", shown when
  Dossiary for Mac is installed or the profile already has it on). `ProfileScanRunner.runAndHandOver` runs the
  scan, then calls the hand-over closure with the saved files; `DossiaryHandOver` (App) sends them with
  `NSWorkspace.open(_:withApplicationAt:)`, i.e. the system's open-documents event, to bundle id
  `com.aarneaarebye.dossiary-mac`. No custom URL scheme on purpose: a web page could trigger one. The caller
  must be unsandboxed (a sandboxed process gets kLSAppDoesNotClaimTypeErr for an app without document types);
  the helper is not sandboxed (no `com.apple.security.app-sandbox` entitlement anywhere in the build or
  signing scripts; `codesign` is run without `--entitlements`). A failed hand-over only shows in the
  notification; the folder copy always exists.
- `.worktrees/`, `.superpowers/`, and `macos/build`, `macos/dist`, `macos/.build*` are git-ignored.
