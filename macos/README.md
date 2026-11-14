# Dossiary Scan Helper for macOS

A menu bar app that lets [Dossiary](https://github.com/AarneAarebye/Dossiary) scan with any scanner
macOS supports (USB, network and AirPrint/eSCL scanners that Image Capture sees). It speaks
[protocol version 2](../PROTOCOL.md) on `127.0.0.1:8766`.

With Dossiary's "Make scans searchable automatically", scans come back at once and the helper makes them searchable in the background with macOS's own text recognition (Vision); results wait in `~/Library/Application Support/dossiary-scan-helper/ocr-jobs/` until Dossiary fetches them, at most 7 days.

**Photos.** A scanner that has a flatbed can scan to JPEG or PNG (`format`) over a chosen area
(`area`): local scanners offer `full` (the whole glass, the default) and the standard areas that fit
(`a4`, `a5`, `a6`, `10x15`, `13x18`), and the Pi's scanners show the formats and areas their server
offers. Images come only from the flatbed (the feeder is PDF only), JPEG can't be black & white,
images are not made searchable, and a scan over 100 megapixels is refused with a message saying what
to change. The protocol text is in [`PROTOCOL.md`](../PROTOCOL.md) ("Formats and areas").

**Button scans.** A scan made with a button on a Pi arrives in the helper's button-scan folder (menu
"Folder for button scans…", default `~/Documents/Scans`); point it at a library's Inbox so Dossiary
imports it. The helper needs 0.6.0 and a server with scanix500 0.10.0; PDFs wait on the server while
the helper is off. Each button press on the Pi also plays a
sound (Pop for a scan button, Hero for finish); the menu item "Sound on button press" switches it
off. The sound needs a scan server with scanix500 0.10.1 or newer. The calls are described in [`PROTOCOL.md`](../PROTOCOL.md) ("Button scans").

**Scan profiles.** A profile is a saved scan: a name, a scanner, the scan settings (source, both sides,
color, resolution, format, paper size, searchable PDF) and a folder. The menu lists the profiles; clicking
one scans with those settings and saves the result in the profile's folder, as
`scan_YYYY-MM-DD_HHMMSS.<ext>` (with `_1`, `_2`… for several files; an existing file is never overwritten).
"Scan profiles…" opens the window where profiles are added, edited and removed; they are kept in
`profiles.json` in the helper's Application Support folder. The scan goes through the same path as a scan
from Dossiary, so only one scan runs at a time per scanner. With "Make the PDF searchable (OCR)" the helper
waits up to 10 minutes for the text recognition, then keeps the plain scan. A Pi's scanner can only be used
in a profile once the Pi has been added with "Add network scanner…". A profile whose scanner is off can
still change its name and folder.

**Also send to Dossiary.** A profile can have the switch "Also send to Dossiary" (shown when Dossiary for
Mac is installed; off for a new profile). After a scan is saved in the profile's folder, the helper hands
the saved files to Dossiary for Mac, which adds them to its last used library (or says so if no library is
open). The folder copy always exists, also when the hand-over fails or Dossiary isn't installed; the
notification says what happened. The target app is the running Dossiary first, then the copy in /Applications/Dossiary, then the one LaunchServices prefers. It needs Dossiary for Mac 0.5.1 or later. The helper must not be sandboxed for this (it isn't).

To install a release, see [docs/install-macos.md](../docs/install-macos.md).

## Build and test

Needs macOS 14 or later and the Command Line Tools (`xcode-select --install`); Xcode isn't needed.

    cd macos
    scripts/test.sh                 # unit tests (swift test, plus the Testing plugin path)
    scripts/run-conformance.sh      # the conformance suite against --fake-scanners
    swift run dossiary-scan-helper --fake-scanners   # menu bar app with the nine fake scanners

`--headless` runs without the menu bar icon and logs to the terminal too. The log file is
`~/Library/Logs/dossiary-scan-helper/helper.log`.

## Languages

The menu and panels are in English, German, Spanish, French, Chinese (Simplified and Traditional) and
Armenian. All texts live in `Localization/Localizable.xcstrings` (and the network-permission prompt in
`Localization/InfoPlist.xcstrings`); the English text is the key. Xcode isn't needed: `scripts/build-app.sh`
turns the catalogs into `<lang>.lproj` files with `scripts/strings_from_catalog.py`. To change a text,
edit the catalog (by hand or in Xcode) and keep every language: `python3 -m unittest discover -s
scripts -p 'test_*.py'` fails on a missing translation, a changed placeholder, or a key the code uses
that isn't in the catalog. After a build, `scripts/check-localized-app.sh` prints the menu in four
languages; `dossiary-scan-helper --print-menu -AppleLanguages "(fr)"` shows any other. Messages the
helper sends to Dossiary stay English.

## Release

1. Bump `HelperVersion.string` in `Sources/HelperCore/Version.swift`.
2. `scripts/build-app.sh` builds an unsigned universal app in `build/`.
3. `scripts/sign-and-notarize.sh` signs, notarizes and staples it, and writes
   `dist/DossiaryScanHelper-<version>-macos.zip`.
4. Run the [hardware checklist](../docs/manual-check-macos.md) with the signed app.
5. Tag `macos-v<version>` and attach the zip to a GitHub release.
6. `scripts/install-app.sh` installs the app into `/Applications/Dossiary`, starts it, and
   removes the copy in `build/`. "Open at Login" registers the app by its bundle id, and
   macOS opens whichever copy it knows under that id -- with a second copy left in
   `build/`, the login item pointed there instead of the installed app.

### Signing setup (once per Mac)

Nothing here goes into the repo or CI.

1. **Certificate.** In Keychain Access choose Keychain Access › Certificate Assistant › Request a
   Certificate From a Certificate Authority…, enter your email, choose "Saved to disk". On
   developer.apple.com › Certificates, add a **Developer ID Application** certificate with that
   request, download it and double-click it. `security find-identity -v -p codesigning` then lists
   it. If more than one Developer ID Application certificate is installed, choose one with
   `DEVELOPER_ID="Developer ID Application: <name> (<team id>)" scripts/sign-and-notarize.sh`.
2. **Notarization password.** At account.apple.com › Sign-In and Security › App-Specific Passwords,
   create one, then run (it asks for the password and keeps it in the keychain):

       xcrun notarytool store-credentials dossiary-notary --apple-id <your Apple ID> --team-id <your team id>

   The team id is on developer.apple.com › Membership details.

   **Or an API key.** If `~/.config/apple-api/` holds an App Store Connect key of the app-manager role
   (`AuthKey_*APP_MANAGER_<keyid>.p8`) and an `api-key.env` with `ISSUER=<issuer id>`, the script uses that
   key first and the keychain profile is not needed. Keep the folder mode 700 and the files 600.
