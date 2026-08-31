#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

characters() {
  LC_ALL=en_US.UTF-8 wc -m < "$1" | tr -d ' '
}

check_limit() {
  local file="$1"
  local maximum="$2"
  local count
  count="$(characters "$file")"
  (( count <= maximum + 1 )) || fail "$file has $count characters including its final newline; limit is $maximum."
}

check_image() {
  local file="$1"
  local expected_width="$2"
  local expected_height="$3"
  [[ -f "$file" ]] || fail "Missing screenshot: $file"
  local properties width height alpha
  properties="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$file" 2>/dev/null)"
  width="$(awk '/pixelWidth:/ {print $2}' <<< "$properties")"
  height="$(awk '/pixelHeight:/ {print $2}' <<< "$properties")"
  alpha="$(awk '/hasAlpha:/ {print $2}' <<< "$properties")"
  [[ "$width" == "$expected_width" && "$height" == "$expected_height" ]] || \
    fail "$file is ${width}x${height}; expected ${expected_width}x${expected_height}."
  [[ "$alpha" == "no" ]] || fail "$file contains an alpha channel."
}

for locale in en-US ko-KR; do
  for field in name subtitle promotional_text keywords description release_notes support_url marketing_url privacy_url; do
    [[ -s "appstore/metadata/$locale/$field.txt" ]] || fail "Missing metadata: $locale/$field.txt"
  done
  check_limit "appstore/metadata/$locale/name.txt" 30
  check_limit "appstore/metadata/$locale/subtitle.txt" 30
  check_limit "appstore/metadata/$locale/promotional_text.txt" 170
  check_limit "appstore/metadata/$locale/keywords.txt" 100
done

for section in today japanese books firmware; do
  check_image "appstore/screenshots/en-US/iphone-6.9/$section.png" 1320 2868
  check_image "appstore/screenshots/en-US/ipad-13/$section.png" 2064 2752
  check_image "appstore/screenshots/en-US/mac-16x10/$section.png" 1440 900
done

check_image "Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" 1024 1024
plutil -lint appstore/ExportOptions.plist >/dev/null
plutil -extract ITSAppUsesNonExemptEncryption raw Support/Pocket-Info.plist | grep -qx false || \
  fail "iOS export-compliance flag is not false."
plutil -extract ITSAppUsesNonExemptEncryption raw Support/PocketMac-Info.plist | grep -qx false || \
  fail "macOS export-compliance flag is not false."

echo "App Store source package is internally valid."
echo "Account-only work remains: create the app record, add a review phone, upload signed builds, and attach the physical-reader video URL."
