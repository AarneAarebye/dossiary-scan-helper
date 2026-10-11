#!/bin/bash
# Builds an unsigned universal "Dossiary Scan Helper.app" into macos/build/.
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
lipo -archs "$APP/Contents/MacOS/dossiary-scan-helper"
echo "Built $APP ($VERSION)"
