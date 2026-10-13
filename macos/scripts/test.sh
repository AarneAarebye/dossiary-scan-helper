#!/bin/bash
# Runs the unit tests. Newer Command Line Tools keep the Swift Testing macro plugin in
# usr/lib/swift/host/plugins/testing/, where SwiftPM doesn't look; pass that folder when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
