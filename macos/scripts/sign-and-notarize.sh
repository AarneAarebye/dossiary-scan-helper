#!/bin/bash
# Signs the app with Developer ID (hardened runtime), notarizes it, staples the ticket and zips it for release.
# Needs, once per Mac (never in the repo or CI):
#   - a "Developer ID Application" certificate in the login keychain;
#   - notarytool credentials: xcrun notarytool store-credentials dossiary-notary --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/HelperCore/Version.swift)
APP="build/Dossiary Scan Helper.app"
IDENTITY="${DEVELOPER_ID:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-dossiary-notary}"

[ -d "$APP" ] || { echo "Run scripts/build-app.sh first."; exit 1; }
identities=$(security find-identity -v -p codesigning || true)
grep -qF "$IDENTITY" <<<"$identities" || {
  echo "No \"$IDENTITY\" certificate in the keychain. See macos/README.md, \"Signing setup\"."; exit 1; }

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

mkdir -p dist
SUBMIT="dist/notarize-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait
rm "$SUBMIT"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ZIP="dist/DossiaryScanHelper-$VERSION-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Ready: $ZIP"
