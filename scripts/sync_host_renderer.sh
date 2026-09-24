#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/sync_host_renderer.sh SIBLING_APPLE_HOST_BUILD_DIRECTORY" >&2
  exit 1
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$repo_dir/scripts/host_renderer_artifact.py" import "$1"
