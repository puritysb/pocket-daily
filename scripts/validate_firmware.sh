#!/bin/bash
set -euo pipefail

# Compile the app's real validator for an offline, read-only artifact check.
if [[ $# -ne 2 ]]; then
  echo "Usage: bash scripts/validate_firmware.sh IMAGE EXPECTED_VERSION" >&2
  exit 1
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/.build"
artifact_check_dir="$(mktemp -d "$repo_dir/.build/firmware-check.XXXXXX")"
trap 'rm -f "$artifact_check_dir/check"; rmdir "$artifact_check_dir"' EXIT
xcrun swiftc "$repo_dir/Sources/FirmwareImageValidator.swift" \
  "$repo_dir/scripts/FirmwareArtifactCheck.swift" -o "$artifact_check_dir/check"
"$artifact_check_dir/check" "$1" "$2"
