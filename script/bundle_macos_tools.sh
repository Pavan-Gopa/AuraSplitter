#!/usr/bin/env bash
set -euo pipefail

DEST_DIR="${1:?usage: bundle_macos_tools.sh <destination> [ffmpeg] [ffprobe]}"
FFMPEG_SOURCE="${2:-$(command -v ffmpeg 2>/dev/null || true)}"
FFPROBE_SOURCE="${3:-$(command -v ffprobe 2>/dev/null || true)}"

if [[ -z "$FFMPEG_SOURCE" || -z "$FFPROBE_SOURCE" ]]; then
  echo "ffmpeg and ffprobe are required to build the app bundle" >&2
  exit 1
fi

mkdir -p "$DEST_DIR/bin" "$DEST_DIR/lib"
cp -f "$(realpath "$FFMPEG_SOURCE")" "$DEST_DIR/bin/ffmpeg"
cp -f "$(realpath "$FFPROBE_SOURCE")" "$DEST_DIR/bin/ffprobe"
chmod +x "$DEST_DIR/bin/ffmpeg" "$DEST_DIR/bin/ffprobe"

queue=("$DEST_DIR/bin/ffmpeg" "$DEST_DIR/bin/ffprobe")
processed=()

contains_processed() {
  local candidate="$1"
  local item
  for item in "${processed[@]-}"; do
    [[ "$item" == "$candidate" ]] && return 0
  done
  return 1
}

while ((${#queue[@]} > 0)); do
  current="${queue[0]}"
  queue=("${queue[@]:1}")
  contains_processed "$current" && continue
  processed+=("$current")

  while IFS= read -r dependency; do
    case "$dependency" in
      /opt/homebrew/*|/usr/local/*)
        [[ -e "$dependency" ]] || continue
        source="$(realpath "$dependency")"
        name="$(basename "$source")"
        target="$DEST_DIR/lib/$name"
        if [[ ! -e "$target" ]]; then
          cp -f "$source" "$target"
          chmod +x "$target"
        fi
        if [[ "$current" == "$DEST_DIR/bin/"* ]]; then
          replacement="@loader_path/../lib/$name"
        else
          replacement="@loader_path/$name"
        fi
        install_name_tool -change "$dependency" "$replacement" "$current"
        install_name_tool -id "@rpath/$name" "$target" >/dev/null 2>&1 || true
        queue+=("$target")
        ;;
    esac
  done < <(otool -L "$current" | awk 'NR > 1 { print $1 }')
  codesign --force --sign - "$current" >/dev/null
done

echo "Bundled FFmpeg tools and $((${#processed[@]} - 2)) dynamic libraries"
