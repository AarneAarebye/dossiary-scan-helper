#!/bin/bash
# Builds a universal "Dossiary Scan Helper.app" into macos/build/ (signed with the Developer ID if available).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/HelperCore/Version.swift)
APP="build/Dossiary Scan Helper.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINS=()
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build-$ARCH"
  BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build-$ARCH" --show-bin-path)/dossiary-scan-helper")
done
lipo -create -output "$APP/Contents/MacOS/dossiary-scan-helper" "${BINS[@]}"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
python3 scripts/strings_from_catalog.py --out "$APP/Contents/Resources" Localization/Localizable.xcstrings Localization/InfoPlist.xcstrings > /dev/null
for f in "$APP"/Contents/Resources/*.lproj/*.strings; do plutil -lint -s "$f"; done
lipo -archs "$APP/Contents/MacOS/dossiary-scan-helper"
# Sign with the Developer ID when it is in the keychain (not notarized: that is sign-and-notarize.sh). A stable
# signature keeps the Keychain's "Always Allow" for the remote-server tokens across rebuilds; an ad-hoc one makes
# every rebuild a new app that asks again. Without the certificate the app stays unsigned (ad hoc).
IDENTITY="${DEVELOPER_ID:-Developer ID Application}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with $IDENTITY"
fi
echo "Built $APP ($VERSION)"
