#!/bin/bash
# Signs the app with Developer ID (hardened runtime), notarizes it, staples the ticket and zips it for release.
# Needs, once per Mac (never in the repo or CI):
#   - a "Developer ID Application" certificate in the login keychain;
#   - notarytool credentials, either of:
#       * the App Store Connect API key of the app-manager role in ~/.config/apple-api (AuthKey_*APP_MANAGER_<keyid>.p8,
#         the issuer id as ISSUER in api-key.env there); used first when present, or
#       * a keychain profile: xcrun notarytool store-credentials dossiary-notary --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/HelperCore/Version.swift)
APP="build/Dossiary Scan Helper.app"
IDENTITY="${DEVELOPER_ID:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-dossiary-notary}"
APPLE_DIR="${APPLE_API_DIR:-$HOME/.config/apple-api}"
# The key file is never read or printed here; only its name (the key id) and the issuer id are used.
KEY_P8=$(ls "$APPLE_DIR"/AuthKey_*APP_MANAGER_*.p8 2>/dev/null | head -1 || true)
NOTARY_AUTH=(--keychain-profile "$PROFILE")
if [ -n "$KEY_P8" ] && [ -f "$APPLE_DIR/api-key.env" ]; then
  KEY_ID=$(basename "$KEY_P8" .p8); KEY_ID=${KEY_ID##*_}
  ISSUER=$(. "$APPLE_DIR/api-key.env"; printf '%s' "${ISSUER:-}")
  [ -n "$ISSUER" ] && NOTARY_AUTH=(--key "$KEY_P8" --key-id "$KEY_ID" --issuer "$ISSUER")
fi

[ -d "$APP" ] || { echo "Run scripts/build-app.sh first."; exit 1; }
identities=$(security find-identity -v -p codesigning || true)
grep -qF "$IDENTITY" <<<"$identities" || {
  echo "No \"$IDENTITY\" certificate in the keychain. See macos/README.md, \"Signing setup\"."; exit 1; }

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

mkdir -p dist
SUBMIT="dist/notarize-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" "${NOTARY_AUTH[@]}" --wait
rm "$SUBMIT"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ZIP="dist/DossiaryScanHelper-$VERSION-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Ready: $ZIP"
