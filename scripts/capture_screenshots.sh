#!/bin/bash
# Regenerates the App Store screenshots from the shipping demo interface.
#
# Drives the real app through the PocketUITests (iPhone 6.9", iPad 13") and
# PocketMacUITests (Mac 16:10) targets, exports the screenshot attachments
# from each result bundle, and flattens every capture to an opaque PNG at
# Apple's accepted size. Run after any user-facing UI change and before
# `scripts/validate_app_store.sh`.
#
# No special permissions are required: the iOS sets come from simulator UI tests and
# the Mac set is rendered from the shipping views in an off-screen window.
set -euo pipefail

cd "$(dirname "$0")/.."

IPHONE_NAME="${POCKET_IPHONE_SIMULATOR:-iPhone 17 Pro Max}"
IPAD_NAME="${POCKET_IPAD_SIMULATOR:-iPad Pro 13-inch (M5)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

simulator_udid() {
  xcrun simctl list devices available -j | \
    jq -r --arg name "$1" '.devices[][] | select(.name == $name) | .udid' | head -1
}

capture_ios() {
  local name="$1" folder="$2" width="$3" height="$4" udid
  udid="$(simulator_udid "$name")"
  [[ -n "$udid" ]] || { echo "ERROR: simulator '$name' is not available." >&2; exit 1; }
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 --cellularBars 4 >/dev/null
  xcodebuild test \
    -project Pocket.xcodeproj -scheme Pocket -destination "id=$udid" \
    -derivedDataPath .build/screenshots -resultBundlePath "$WORK/$folder.xcresult" \
    -only-testing:PocketUITests CODE_SIGNING_ALLOWED=NO -quiet
  xcrun simctl status_bar "$udid" clear >/dev/null
  xcrun simctl shutdown "$udid" >/dev/null
  publish "$folder" "$width" "$height"
}

capture_mac() {
  # A unit test, not a UI test: the macOS UI-test runner needs the Accessibility
  # permission to enable automation mode, which cannot be granted from a script.
  # PocketMacTests hosts the shipping views in an off-screen window instead.
  xcodebuild test \
    -project Pocket.xcodeproj -scheme PocketMac -destination 'platform=macOS' \
    -derivedDataPath .build/screenshots -resultBundlePath "$WORK/mac-16x10.xcresult" \
    -only-testing:PocketMacTests CODE_SIGNING_ALLOWED=NO -quiet
  publish mac-16x10 2880 1800
}

publish() {
  local folder="$1" width="$2" height="$3"
  local target="appstore/screenshots/en-US/$folder"
  local export="$WORK/$folder-attachments"
  xcrun xcresulttool export attachments --path "$WORK/$folder.xcresult" --output-path "$export" >/dev/null
  mkdir -p "$target"
  rm -f "$target"/*.png
  local count=0
  while IFS=$'\t' read -r exported name; do
    [[ "$exported" == *.png ]] || continue
    swift scripts/flatten_png.swift "$export/$exported" "$target/${name%%_*}.png" "$width" "$height"
    count=$((count + 1))
  done < <(jq -r '.[].attachments[] | [.exportedFileName, .suggestedHumanReadableName] | @tsv' "$export/manifest.json")
  (( count > 0 )) || { echo "ERROR: no screenshots were exported for $folder." >&2; exit 1; }
  echo "Wrote $count screenshots to $target"
}

capture_ios "$IPHONE_NAME" iphone-6.9 1320 2868
capture_ios "$IPAD_NAME" ipad-13 2064 2752
capture_mac
./scripts/validate_app_store.sh
