#!/bin/bash
# Installs the built app as this Mac's copy (default /Applications/Dossiary) and starts it.
# "Open at Login" (SMAppService) registers the app by its bundle id, and macOS then opens
# whichever copy Launch Services knows under that id -- so the copy in build/ is removed
# afterwards and only the installed one stays known. dist/'s release zip is kept.
# Usage: scripts/install-app.sh   (after build-app.sh, and sign-and-notarize.sh for a release)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Dossiary Scan Helper.app"
INSTALL_DIR="${SCAN_HELPER_INSTALL_DIR:-/Applications/Dossiary}"
TARGET="$INSTALL_DIR/Dossiary Scan Helper.app"
BUNDLE_ID="com.aarneaarebye.dossiary-scan-helper"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

[ -d "$APP" ] || { echo "Run scripts/build-app.sh first."; exit 1; }

# Quit the running copy (it finishes a scan in progress first) and wait for it.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" > /dev/null 2>&1 || true
for _ in $(seq 1 40); do
  pgrep -f "Dossiary Scan Helper.app/Contents/MacOS/dossiary-scan-helper" > /dev/null || break
  sleep 0.5
done

mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"

# Leave exactly one copy known under the bundle id.
"$LSREGISTER" -u "$APP" || true
rm -rf "$APP"
"$LSREGISTER" -f "$TARGET"

open "$TARGET"
echo "Installed $("$TARGET/Contents/MacOS/dossiary-scan-helper" --version) in $INSTALL_DIR and started it."
