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

review_sample="appstore/review/Pocket-Daily-Review-Sample.epub"
[[ -s "$review_sample" ]] || fail "Missing generated review transfer sample: $review_sample"
[[ -s appstore/testflight/TEST_PLAN.md ]] || fail "Missing physical-device TestFlight plan."
unzip -tqq "$review_sample" || fail "The review EPUB is not a valid ZIP container."
[[ "$(zipinfo -1 "$review_sample" | head -1)" == "mimetype" ]] || \
  fail "The review EPUB must store mimetype as its first entry."
[[ "$(unzip -p "$review_sample" mimetype)" == "application/epub+zip" ]] || \
  fail "The review EPUB has an invalid mimetype."

check_image "Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" 1024 1024
for release_script in scripts/package_app_store.sh scripts/verify_app_store_distributions.sh; do
  [[ -x "$release_script" ]] || fail "$release_script must be executable."
  bash -n "$release_script" || fail "$release_script has invalid shell syntax."
done
plutil -lint appstore/ExportOptions.plist appstore/ExportOnlyOptions.plist >/dev/null
plutil -extract destination raw appstore/ExportOptions.plist | grep -qx upload || \
  fail "ExportOptions.plist must remain an explicit upload configuration."
plutil -extract destination raw appstore/ExportOnlyOptions.plist | grep -qx export || \
  fail "ExportOnlyOptions.plist must remain a local export configuration."
for export_options in appstore/ExportOptions.plist appstore/ExportOnlyOptions.plist; do
  plutil -extract method raw "$export_options" | grep -qx app-store-connect || \
    fail "$export_options must use the app-store-connect method."
  plutil -extract teamID raw "$export_options" | grep -qx QF36NDHYHD || \
    fail "$export_options must use organization team QF36NDHYHD."
  plutil -extract distributionBundleIdentifier raw "$export_options" | \
    grep -qx bound.serendipity.pocket.daily || \
    fail "$export_options has the wrong distribution bundle identifier."
done
jq empty appstore/privacy_answers.json appstore/age_rating_answers.json appstore/submission.json >/dev/null || \
  fail "One or more App Store JSON manifests are invalid."
jq -er '.expected_global_rating' appstore/age_rating_answers.json | grep -qx '4+' || \
  fail "The prepared age-rating answers must resolve to the intended 4+ rating."
plutil -lint Sources/PrivacyInfo.xcprivacy >/dev/null
privacy_apis="$(plutil -extract NSPrivacyAccessedAPITypes json -o - Sources/PrivacyInfo.xcprivacy)"
grep -q 'CA92.1' <<< "$privacy_apis" || fail "PrivacyInfo.xcprivacy is missing the app-only UserDefaults reason CA92.1."
grep -q '3B52.1' <<< "$privacy_apis" || fail "PrivacyInfo.xcprivacy is missing the user-selected file metadata reason 3B52.1."
plutil -extract NSPrivacyTracking raw Sources/PrivacyInfo.xcprivacy | grep -qx false || \
  fail "PrivacyInfo.xcprivacy must declare tracking as false."
plutil -extract NSLocationUsageDescription raw Support/PocketMac-Info.plist >/dev/null || \
  fail "The macOS Info.plist is missing NSLocationUsageDescription."
plutil -extract ITSAppUsesNonExemptEncryption raw Support/Pocket-Info.plist | grep -qx false || \
  fail "iOS export-compliance flag is not false."
plutil -extract ITSAppUsesNonExemptEncryption raw Support/PocketMac-Info.plist | grep -qx false || \
  fail "macOS export-compliance flag is not false."

echo "App Store source package is internally valid."
echo "External release work remains: create the App Store Connect record, add the review contact, upload the signed builds, run TestFlight with hardware, and add the physical-reader video URL."
