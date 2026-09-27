#!/bin/bash
# Two-simulator continuity check through a KOReader sync server.
#
# Starts scripts/kosync_dev_server.py (or uses KOSYNC_E2E_SERVER), reads on one
# simulator, then opens the same book on another and expects to be offered the
# first device's position. Needs no hardware or accounts; Debug builds accept
# the local http server. Set KOSYNC_E2E_SERVER=https://… to use a real server.
set -euo pipefail
cd "$(dirname "$0")/.."

FIRST="${POCKET_E2E_FIRST:-iPhone 17 Pro}"
SECOND="${POCKET_E2E_SECOND:-iPad Pro 11-inch (M5)}"
DERIVED="${POCKET_E2E_DERIVED_DATA:-.build/e2e}"
RESULTS="${POCKET_E2E_RESULTS:-.build/results/e2e-$(date +%s)}"
PORT="${KOSYNC_E2E_PORT:-8765}"
SERVER="${KOSYNC_E2E_SERVER:-}"
USER_NAME="pd_e2e_$(date +%s)"
PASSWORD="e2e-$(uuidgen | cut -c1-8)"
SERVER_PID=""

cleanup() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

if [[ -z "$SERVER" ]]; then
  python3 scripts/kosync_dev_server.py --port "$PORT" > "${RESULTS}-server.log" 2>&1 &
  SERVER_PID=$!
  SERVER="http://127.0.0.1:$PORT"
  sleep 1
fi
/usr/bin/curl -fsS "$SERVER/healthcheck" >/dev/null || { echo "ERROR: $SERVER is not responding." >&2; exit 1; }

udid() {
  xcrun simctl list devices available -j | \
    jq -r --arg name "$1" '.devices[][] | select(.name == $name or .udid == $name) | .udid' | head -1
}

run() {
  local device="$1" test="$2" id
  id="$(udid "$device")"
  [[ -n "$id" ]] || { echo "ERROR: simulator '$device' is not available." >&2; exit 1; }
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl bootstatus "$id" -b >/dev/null
  TEST_RUNNER_KOSYNC_E2E_SERVER="$SERVER" TEST_RUNNER_KOSYNC_E2E_USER="$USER_NAME" \
  TEST_RUNNER_KOSYNC_E2E_PASSWORD="$PASSWORD" \
  xcodebuild test -project Pocket.xcodeproj -scheme Pocket -destination "id=$id" \
    -derivedDataPath "$DERIVED" -resultBundlePath "$RESULTS-$test.xcresult" \
    -only-testing:"PocketUITests/PocketSyncEndToEndTests/$test" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -quiet
}

run "$FIRST" test1ReadAndUpload
run "$SECOND" test2OfferedAndJump
echo "Continuity passed: $FIRST → $SECOND through $SERVER as $USER_NAME. Results: $RESULTS-*.xcresult"
