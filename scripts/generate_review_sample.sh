#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

source_dir="appstore/review/sample-src"
output="appstore/review/Pocket-Daily-Review-Sample.epub"
temporary_dir="$(mktemp -d)"
generated="$temporary_dir/Pocket-Daily-Review-Sample.epub"
trap 'rm -rf "$temporary_dir"' EXIT

printf 'application/epub+zip' > "$temporary_dir/mimetype"
cp -R "$source_dir/META-INF" "$source_dir/EPUB" "$temporary_dir/"

(
  cd "$temporary_dir"
  zip -X -q -0 "$generated" mimetype
  zip -X -q -r "$generated" META-INF EPUB
)

mv "$generated" "$output"

echo "Generated $output"
