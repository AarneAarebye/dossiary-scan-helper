# Dossiary Scan Helper for macOS

A menu bar app that lets [Dossiary](https://github.com/AarneAarebye/Dossiary) scan with any scanner
macOS supports (USB, network and AirPrint/eSCL scanners that Image Capture sees). It speaks
[protocol version 2](../PROTOCOL.md) on `127.0.0.1:8766`.

With Dossiary's "Make scans searchable automatically", scans come back at once and the helper makes them searchable in the background with macOS's own text recognition (Vision); results wait in `~/Library/Application Support/dossiary-scan-helper/ocr-jobs/` until Dossiary fetches them, at most 7 days.

To install a release, see [docs/install-macos.md](../docs/install-macos.md).

## Build and test

Needs macOS 14 or later and the Command Line Tools (`xcode-select --install`); Xcode isn't needed.

    cd macos
    scripts/test.sh                 # unit tests (swift test, plus the Testing plugin path)
    scripts/run-conformance.sh      # the conformance suite against --fake-scanners
    swift run dossiary-scan-helper --fake-scanners   # menu bar app with the eight fake scanners

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
