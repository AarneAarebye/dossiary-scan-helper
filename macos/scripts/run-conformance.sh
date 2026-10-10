#!/bin/bash
# Builds the helper, starts it with fake scanners and runs the repo's conformance suite against it.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8766}"
swift build
.build/debug/dossiary-scan-helper --headless --fake-scanners --port "$PORT" > .build/conformance-helper.log 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:$PORT/health" > /dev/null; then break; fi
  sleep 0.2
done
curl -sf "http://127.0.0.1:$PORT/health" > /dev/null || { echo "helper did not start"; cat .build/conformance-helper.log; exit 1; }
cd ..
SCAN_HELPER_URL="http://127.0.0.1:$PORT" python3 -m unittest discover -s conformance -v
