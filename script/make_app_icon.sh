#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <source.svg> <output.icns>" >&2
  exit 2
fi

SOURCE_SVG="$1"
OUTPUT_ICNS="$2"

if [[ ! -f "$SOURCE_SVG" ]]; then
  echo "missing source SVG: $SOURCE_SVG" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_PNG="$TMP_DIR/base.png"
ICONSET="$TMP_DIR/KirtanSplitter.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT_ICNS")"

sips -s format png "$SOURCE_SVG" --out "$BASE_PNG" >/dev/null

make_icon() {
  local pixels="$1"
  local filename="$2"
  sips -z "$pixels" "$pixels" "$BASE_PNG" --out "$ICONSET/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT_ICNS"
