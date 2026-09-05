#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 <ios.ipa> <macos.pkg> <evidence.json>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage

ipa_path="$1"
pkg_path="$2"
evidence_path="$3"

[[ -s "$ipa_path" ]] || fail "Missing iOS IPA: $ipa_path"
[[ -s "$pkg_path" ]] || fail "Missing macOS PKG: $pkg_path"
[[ ! -e "$evidence_path" ]] || fail "Refusing to overwrite evidence: $evidence_path"
[[ -d "$(dirname "$evidence_path")" ]] || fail "Evidence directory does not exist: $(dirname "$evidence_path")"

for command_name in codesign jq lipo pkgutil plutil security shasum unzip zipinfo; do
  command -v "$command_name" >/dev/null || fail "Required command is unavailable: $command_name"
done

expected_bundle_id="$(jq -er '.bundle_id' appstore/submission.json)"
expected_version="$(jq -er '.version' appstore/submission.json)"
expected_build="$(jq -er '.build' appstore/submission.json)"
expected_team="$(plutil -extract teamID raw appstore/ExportOnlyOptions.plist)"

[[ "$(plutil -extract destination raw appstore/ExportOnlyOptions.plist)" == "export" ]] || \
  fail "ExportOnlyOptions.plist is not a local-only export configuration."

inspection_root="$(mktemp -d "${TMPDIR:-/tmp}/pocket-daily-verify.XXXXXX")"
cleanup() {
  case "$inspection_root" in
    "${TMPDIR:-/tmp}"/pocket-daily-verify.*)
      find "$inspection_root" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

ipa_entries="$(zipinfo -1 "$ipa_path")"
if grep -Eq '(^/|(^|/)\.\.(/|$))' <<< "$ipa_entries"; then
  fail "The iOS IPA contains an unsafe archive path."
fi
unzip -tqq "$ipa_path" || fail "The iOS IPA ZIP container is invalid."
unzip -q "$ipa_path" -d "$inspection_root/ios"
pkgutil --expand-full "$pkg_path" "$inspection_root/macpkg" >/dev/null

ios_app_count="$(find "$inspection_root/ios/Payload" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
mac_app_count="$(find "$inspection_root/macpkg" -type d -name '*.app' | wc -l | tr -d ' ')"
[[ "$ios_app_count" == "1" ]] || fail "Expected one app in the IPA; found $ios_app_count."
[[ "$mac_app_count" == "1" ]] || fail "Expected one app in the PKG; found $mac_app_count."

ios_app="$(find "$inspection_root/ios/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
mac_app="$(find "$inspection_root/macpkg" -type d -name '*.app' -print -quit)"
ios_info="$ios_app/Info.plist"
mac_info="$mac_app/Contents/Info.plist"

for app in "$ios_app" "$mac_app"; do
  codesign --verify --deep --strict --verbose=2 "$app"
  signing_details="$(codesign -dv --verbose=2 "$app" 2>&1)"
  grep -q "^Authority=Apple Distribution:" <<< "$signing_details" || \
    fail "$app is not signed with Apple Distribution."
  grep -q "^TeamIdentifier=$expected_team$" <<< "$signing_details" || \
    fail "$app is signed for the wrong team."
done

for info in "$ios_info" "$mac_info"; do
  [[ "$(plutil -extract CFBundleIdentifier raw "$info")" == "$expected_bundle_id" ]] || \
    fail "$info has the wrong bundle identifier."
  [[ "$(plutil -extract CFBundleShortVersionString raw "$info")" == "$expected_version" ]] || \
    fail "$info has the wrong marketing version."
  [[ "$(plutil -extract CFBundleVersion raw "$info")" == "$expected_build" ]] || \
    fail "$info has the wrong build number."
done

ios_executable="$ios_app/$(plutil -extract CFBundleExecutable raw "$ios_info")"
mac_executable="$mac_app/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$mac_info")"
ios_architectures="$(lipo -archs "$ios_executable")"
mac_architectures="$(lipo -archs "$mac_executable")"
[[ " $ios_architectures " == *" arm64 "* ]] || fail "The IPA does not contain arm64."
[[ " $mac_architectures " == *" arm64 "* ]] || fail "The macOS app does not contain arm64."
[[ " $mac_architectures " == *" x86_64 "* ]] || fail "The macOS app does not contain x86_64."

ios_entitlements="$inspection_root/ios-entitlements.plist"
mac_entitlements="$inspection_root/mac-entitlements.plist"
codesign -d --entitlements :- "$ios_app" 2>/dev/null > "$ios_entitlements"
codesign -d --entitlements :- "$mac_app" 2>/dev/null > "$mac_entitlements"

[[ "$(plutil -extract application-identifier raw "$ios_entitlements")" == "$expected_team.$expected_bundle_id" ]] || \
  fail "The IPA application identifier is incorrect."
[[ "$(plutil -extract get-task-allow raw "$ios_entitlements")" == "false" ]] || \
  fail "The IPA still permits debugger attachment."
[[ "$(plutil -extract beta-reports-active raw "$ios_entitlements")" == "true" ]] || \
  fail "The IPA is missing the App Store beta-report entitlement."
[[ "$(plutil -extract 'com\.apple\.developer\.networking\.HotspotConfiguration' raw "$ios_entitlements")" == "true" ]] || \
  fail "The IPA is missing Hotspot Configuration."

[[ "$(plutil -extract 'com\.apple\.application-identifier' raw "$mac_entitlements")" == "$expected_team.$expected_bundle_id" ]] || \
  fail "The macOS application identifier is incorrect."
for entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.device.bluetooth \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.network.client \
  com.apple.security.personal-information.location; do
  entitlement_path="${entitlement//./\.}"
  [[ "$(plutil -extract "$entitlement_path" raw "$mac_entitlements")" == "true" ]] || \
    fail "The macOS app is missing entitlement: $entitlement"
done

[[ -s "$ios_app/PrivacyInfo.xcprivacy" ]] || fail "The IPA is missing PrivacyInfo.xcprivacy."
[[ -s "$mac_app/Contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "The macOS app is missing PrivacyInfo.xcprivacy."
cmp -s Sources/PrivacyInfo.xcprivacy "$ios_app/PrivacyInfo.xcprivacy" || \
  fail "The IPA privacy manifest differs from the source manifest."
cmp -s Sources/PrivacyInfo.xcprivacy "$mac_app/Contents/Resources/PrivacyInfo.xcprivacy" || \
  fail "The macOS privacy manifest differs from the source manifest."

ios_profile="$inspection_root/ios-profile.plist"
mac_profile="$inspection_root/mac-profile.plist"
security cms -D -i "$ios_app/embedded.mobileprovision" > "$ios_profile"
security cms -D -i "$mac_app/Contents/embedded.provisionprofile" > "$mac_profile"
for profile in "$ios_profile" "$mac_profile"; do
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile")" == "$expected_team" ]] || \
    fail "A Store provisioning profile belongs to the wrong team."
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$ios_profile")" == "false" ]] || \
  fail "The iOS provisioning profile is not a Store profile."

pkg_signature="$inspection_root/pkg-signature.txt"
pkgutil --check-signature "$pkg_path" > "$pkg_signature"
grep -q "$expected_team" "$pkg_signature" || fail "The installer package is signed for the wrong team."

ipa_sha256="$(shasum -a 256 "$ipa_path" | awk '{print $1}')"
pkg_sha256="$(shasum -a 256 "$pkg_path" | awk '{print $1}')"
ipa_size="$(stat -f '%z' "$ipa_path")"
pkg_size="$(stat -f '%z' "$pkg_path")"
verified_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
evidence_tmp="$inspection_root/release-evidence.json"

jq -n \
  --arg verified_at "$verified_at" \
  --arg bundle_id "$expected_bundle_id" \
  --arg version "$expected_version" \
  --arg build "$expected_build" \
  --arg team_id "$expected_team" \
  --arg ipa "$ipa_path" \
  --arg ipa_sha256 "$ipa_sha256" \
  --arg ios_architectures "$ios_architectures" \
  --argjson ipa_size "$ipa_size" \
  --arg pkg "$pkg_path" \
  --arg pkg_sha256 "$pkg_sha256" \
  --arg macos_architectures "$mac_architectures" \
  --argjson pkg_size "$pkg_size" \
  '{
    verified_at: $verified_at,
    bundle_id: $bundle_id,
    version: $version,
    build: $build,
    team_id: $team_id,
    ios: {
      artifact: $ipa,
      bytes: $ipa_size,
      sha256: $ipa_sha256,
      architectures: ($ios_architectures | split(" ")),
      apple_distribution_signed: true,
      store_profile: true,
      hotspot_configuration: true,
      debugger_attachment: false,
      privacy_manifest_matches_source: true
    },
    macos: {
      artifact: $pkg,
      bytes: $pkg_size,
      sha256: $pkg_sha256,
      architectures: ($macos_architectures | split(" ")),
      apple_distribution_signed: true,
      installer_signed: true,
      store_profile: true,
      sandboxed: true,
      privacy_manifest_matches_source: true
    }
  }' > "$evidence_tmp"

cp "$evidence_tmp" "$evidence_path"

echo "App Store distributions are valid."
echo "Evidence: $evidence_path"
