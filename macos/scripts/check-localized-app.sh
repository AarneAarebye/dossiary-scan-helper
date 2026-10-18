#!/bin/bash
# Prints the built app's menu in four languages and checks one line of each (needs scripts/build-app.sh first).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="build/Dossiary Scan Helper.app/Contents/MacOS/dossiary-scan-helper"
[ -x "$BIN" ] || { echo "Run scripts/build-app.sh first."; exit 1; }
check() {
  local out
  out=$("$BIN" --print-menu -AppleLanguages "($1)")
  grep -qF "$2" <<<"$out" || { echo "$1: expected \"$2\" in:"; echo "$out"; exit 1; }
  echo "$1: ok ($2)"
}
check en "Pair a browser…"
check de "Browser koppeln…"
check zh-Hant "配對瀏覽器…"
check hy "Զուգակցել դիտարկիչ…"
