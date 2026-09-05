#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/package_app_store.sh [--output DIRECTORY] [--skip-tests]

Builds, archives, and locally exports the iOS and macOS App Store products.
This script never uploads a build or changes App Store Connect state.

Options:
  --output DIRECTORY  New output directory. Defaults under .build/app-store/.
  --skip-tests        Skip the simulator test suite for a packaging-only rerun.
  --help              Show this help.
EOF
}

output_root=""
skip_tests=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 && -n "$2" ]] || fail "--output requires a directory."
      output_root="$2"
      shift 2
      ;;
    --skip-tests)
      skip_tests=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

for command_name in jq xcodebuild xcodegen xcrun; do
  command -v "$command_name" >/dev/null || fail "Required command is unavailable: $command_name"
done

version="$(jq -er '.version' appstore/submission.json)"
build="$(jq -er '.build' appstore/submission.json)"
if [[ -z "$output_root" ]]; then
  output_root=".build/app-store/${version}-${build}-$(date -u '+%Y%m%dT%H%M%SZ')"
fi

case "$output_root" in
  /|.|..|"$HOME") fail "Refusing unsafe output directory: $output_root" ;;
esac
[[ ! -e "$output_root" ]] || fail "Refusing to overwrite existing output: $output_root"

[[ "$(plutil -extract destination raw appstore/ExportOnlyOptions.plist)" == "export" ]] || \
  fail "ExportOnlyOptions.plist must use destination=export."

./scripts/validate_app_store.sh
xcodegen generate

mkdir -p \
  "$output_root/archives" \
  "$output_root/derived/tests" \
  "$output_root/exports/ios" \
  "$output_root/exports/macos" \
  "$output_root/logs"
output_root="$(cd "$output_root" && pwd -P)"

system_path="/usr/bin:/bin:/usr/sbin:/sbin"
project_path="$(pwd -P)/Pocket.xcodeproj"

if [[ "$skip_tests" == false ]]; then
  simulator_id="$(xcrun simctl list devices available -j | jq -r '
    [.devices[] | .[]
      | select(.isAvailable == true)
      | select(.name | startswith("iPhone"))]
    | sort_by(if .state == "Booted" then 0 else 1 end)
    | .[0].udid // empty
  ')"
  [[ -n "$simulator_id" ]] || fail "No available iPhone simulator was found."

  echo "Running iOS tests on simulator ${simulator_id}…"
  env PATH="$system_path" /usr/bin/xcodebuild test \
    -quiet \
    -project "$project_path" \
    -scheme Pocket \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$output_root/derived/tests" \
    CODE_SIGNING_ALLOWED=NO \
    | tee "$output_root/logs/ios-tests.log"
fi

echo "Archiving iOS for App Store distribution…"
env PATH="$system_path" /usr/bin/xcodebuild archive \
  -quiet \
  -project "$project_path" \
  -scheme Pocket \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$output_root/archives/Pocket-iOS.xcarchive" \
  -derivedDataPath "$output_root/derived/ios-archive" \
  -allowProvisioningUpdates \
  | tee "$output_root/logs/ios-archive.log"

echo "Exporting the local iOS IPA…"
env PATH="$system_path" /usr/bin/xcodebuild -exportArchive \
  -quiet \
  -archivePath "$output_root/archives/Pocket-iOS.xcarchive" \
  -exportPath "$output_root/exports/ios" \
  -exportOptionsPlist "$(pwd -P)/appstore/ExportOnlyOptions.plist" \
  -allowProvisioningUpdates \
  | tee "$output_root/logs/ios-export.log"

echo "Archiving macOS for App Store distribution…"
env PATH="$system_path" /usr/bin/xcodebuild archive \
  -quiet \
  -project "$project_path" \
  -scheme PocketMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$output_root/archives/Pocket-macOS.xcarchive" \
  -derivedDataPath "$output_root/derived/macos-archive" \
  -allowProvisioningUpdates \
  | tee "$output_root/logs/macos-archive.log"

echo "Exporting the local macOS PKG…"
env PATH="$system_path" /usr/bin/xcodebuild -exportArchive \
  -quiet \
  -archivePath "$output_root/archives/Pocket-macOS.xcarchive" \
  -exportPath "$output_root/exports/macos" \
  -exportOptionsPlist "$(pwd -P)/appstore/ExportOnlyOptions.plist" \
  -allowProvisioningUpdates \
  | tee "$output_root/logs/macos-export.log"

ipa_count="$(find "$output_root/exports/ios" -maxdepth 1 -type f -name '*.ipa' | wc -l | tr -d ' ')"
pkg_count="$(find "$output_root/exports/macos" -maxdepth 1 -type f -name '*.pkg' | wc -l | tr -d ' ')"
[[ "$ipa_count" == "1" ]] || fail "Expected one exported IPA; found $ipa_count."
[[ "$pkg_count" == "1" ]] || fail "Expected one exported PKG; found $pkg_count."

ipa_path="$(find "$output_root/exports/ios" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
pkg_path="$(find "$output_root/exports/macos" -maxdepth 1 -type f -name '*.pkg' -print -quit)"

./scripts/verify_app_store_distributions.sh \
  "$ipa_path" \
  "$pkg_path" \
  "$output_root/release-evidence.json"

source_revision="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  dirty_worktree=true
else
  dirty_worktree=false
fi

if [[ "$skip_tests" == false ]]; then
  xcresult_count="$(find "$output_root/derived/tests/Logs/Test" -maxdepth 1 -type d -name '*.xcresult' | wc -l | tr -d ' ')"
  [[ "$xcresult_count" == "1" ]] || fail "Expected one test result bundle; found $xcresult_count."
  xcresult_path="$(find "$output_root/derived/tests/Logs/Test" -maxdepth 1 -type d -name '*.xcresult' -print -quit)"
  tests_executed=true
  tests_result="passed"
else
  xcresult_path=""
  tests_executed=false
  tests_result="skipped by explicit --skip-tests"
fi

evidence_update="$output_root/release-evidence.updated.json"
jq \
  --arg source_revision "$source_revision" \
  --argjson dirty_worktree "$dirty_worktree" \
  --argjson tests_executed "$tests_executed" \
  --arg tests_result "$tests_result" \
  --arg xcresult "$xcresult_path" \
  '. + {
    source: {
      git_revision: $source_revision,
      dirty_worktree: $dirty_worktree
    },
    tests: {
      executed: $tests_executed,
      result: $tests_result,
      xcresult: (if $xcresult == "" then null else $xcresult end)
    }
  }' "$output_root/release-evidence.json" > "$evidence_update"
mv "$evidence_update" "$output_root/release-evidence.json"

echo
echo "Local App Store package is complete."
echo "Output: $output_root"
echo "No build was uploaded."
