#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
# Debug for dev runs; release via script/release.sh (BUILD_CONFIG=release).
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
# Binary/process name (SwiftPM executable).
APP_NAME="AuraSplitter"
# User-visible brand folders (models, logs, App Support).
BRAND_NAME="AuraSplitter"
LEGACY_BRAND_NAME="KirtanSplitter"
BUNDLE_ID="com.pavan.aurasplitter"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Release version (bumped by script/release.sh; drives CFBundleShortVersionString).
APP_VERSION="$(cat "$ROOT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
APP_VERSION="${APP_VERSION:-1.0.0}"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_SUPPORT="$HOME/Library/Application Support/$BRAND_NAME"
LEGACY_APP_SUPPORT="$HOME/Library/Application Support/$LEGACY_BRAND_NAME"
RUNTIME_BACKEND="$APP_SUPPORT/backend"
RUNTIME_LAUNCHER="$APP_SUPPORT/run_backend.sh"
LEGACY_MODEL_DIR="$LEGACY_APP_SUPPORT/models"
RUNTIME_MODEL_DIR="${KIRTAN_SPLITTER_MODEL_DIR:-$HOME/AI_LOCAL_MODELS/Sound/$BRAND_NAME}"
LEGACY_SOUND_MODEL_DIR="$HOME/AI_LOCAL_MODELS/Sound/$LEGACY_BRAND_NAME"
LOG_FILE="$APP_SUPPORT/logs/backend.log"
PYTHON_REAL=""
SITE_PACKAGES=""
PYTHON_ROOT=""
FFMPEG_BUNDLE_DIR="$APP_RESOURCES"
BACKEND_HOST="127.0.0.1"
BACKEND_PORT="${KIRTAN_SPLITTER_BACKEND_PORT:-51273}"
BACKEND_LABEL="com.pavan.aurasplitter.backend"

cd "$ROOT_DIR"

if [[ ! -x "$ROOT_DIR/.venv/bin/python" ]]; then
  "$ROOT_DIR/script/setup_backend.sh"
fi

PYTHON_REAL="$(realpath "$ROOT_DIR/.venv/bin/python")"
PYTHON_ROOT="$(cd "$(dirname "$PYTHON_REAL")/.." && pwd)"
SITE_PACKAGES="$ROOT_DIR/.venv/lib/python3.11/site-packages"

# Kill legacy KirtanSplitter processes too
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "KirtanSplitter" >/dev/null 2>&1 || true
launchctl remove "$BACKEND_LABEL" >/dev/null 2>&1 || true
launchctl remove "com.pavan.kirtansplitter.backend" >/dev/null 2>&1 || true
pkill -f "backend/server.py" >/dev/null 2>&1 || true
pkill -f "run_backend.sh" >/dev/null 2>&1 || true

swift build -c "$BUILD_CONFIG"
BUILD_BINARY="$(swift build --show-bin-path -c "$BUILD_CONFIG")/$APP_NAME"

rm -rf "$APP_BUNDLE"
rm -rf "$RUNTIME_BACKEND"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$(dirname "$LOG_FILE")" "$RUNTIME_MODEL_DIR"
# Migrate brand folders (ignore-existing keeps AuraSplitter as source of truth once present).
if [[ -d "$LEGACY_APP_SUPPORT" && "$LEGACY_APP_SUPPORT" != "$APP_SUPPORT" ]]; then
  mkdir -p "$APP_SUPPORT"
  rsync -a --ignore-existing "$LEGACY_APP_SUPPORT/" "$APP_SUPPORT/"
fi
if [[ -d "$LEGACY_SOUND_MODEL_DIR" && "$LEGACY_SOUND_MODEL_DIR" != "$RUNTIME_MODEL_DIR" ]]; then
  mkdir -p "$RUNTIME_MODEL_DIR"
  rsync -a --ignore-existing "$LEGACY_SOUND_MODEL_DIR/" "$RUNTIME_MODEL_DIR/"
fi
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
# App icon (.icns for dock) — use AuraSplitter_2 as the primary logo
if [[ -f "$ROOT_DIR/LOGO/AuraSplitter_2.svg" ]]; then
  cp "$ROOT_DIR/LOGO/AuraSplitter_2.svg" "$APP_RESOURCES/AuraSplitter_2.svg"
  "$ROOT_DIR/script/make_app_icon.sh" "$ROOT_DIR/LOGO/AuraSplitter_2.svg" "$APP_RESOURCES/AuraSplitter.icns"
elif [[ -f "$ROOT_DIR/LOGO/AuraSplitter.svg" ]]; then
  "$ROOT_DIR/script/make_app_icon.sh" "$ROOT_DIR/LOGO/AuraSplitter.svg" "$APP_RESOURCES/AuraSplitter.icns"
fi
# Keep white logo as fallback
if [[ -f "$ROOT_DIR/LOGO/AuraSplitter_White.svg" ]]; then
  cp "$ROOT_DIR/LOGO/AuraSplitter_White.svg" "$APP_RESOURCES/AuraSplitter_White.svg"
fi
rm -rf "$RUNTIME_BACKEND"
mkdir -p "$RUNTIME_BACKEND"
rsync -a --delete "$ROOT_DIR/backend/" "$RUNTIME_BACKEND/"
cp "$ROOT_DIR/script/run_backend.sh" "$RUNTIME_LAUNCHER"
chmod +x "$RUNTIME_LAUNCHER"
# Ship backend sources inside the bundle so release installs can self-bootstrap.
mkdir -p "$APP_RESOURCES/backend"
rsync -a --delete "$ROOT_DIR/backend/" "$APP_RESOURCES/backend/"
cp "$ROOT_DIR/script/run_backend.sh" "$APP_RESOURCES/run_backend.sh"

# Ship a relocatable Python runtime and all installed wheels. The uv-managed
# interpreter is standalone; copying it preserves its relative prefix and
# removes the developer's home directory from the release bundle.
rm -rf "$APP_RESOURCES/python"
rsync -a --delete \
  --exclude 'include/' \
  --exclude 'share/' \
  --exclude 'lib/tcl*' \
  --exclude 'lib/tk*' \
  "$PYTHON_ROOT/" "$APP_RESOURCES/python/"
mkdir -p "$APP_RESOURCES/python/lib/python3.11/site-packages"
rsync -a --delete "$SITE_PACKAGES/" "$APP_RESOURCES/python/lib/python3.11/site-packages/"

# FFmpeg is bundled with its Homebrew-linked libraries rewritten to relative
# loader paths, so audio import/export never depends on Homebrew on the user's Mac.
"$ROOT_DIR/script/bundle_macos_tools.sh" "$FFMPEG_BUNDLE_DIR"
if [[ -d "$ROOT_DIR/models" ]]; then
  rsync -a --ignore-existing "$ROOT_DIR/models/" "$RUNTIME_MODEL_DIR/"
fi
if [[ -d "$LEGACY_MODEL_DIR" && "$LEGACY_MODEL_DIR" != "$RUNTIME_MODEL_DIR" ]]; then
  rsync -a --ignore-existing "$LEGACY_MODEL_DIR/" "$RUNTIME_MODEL_DIR/"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AuraSplitter.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>AuraSplitterBackendHost</key>
  <string>$BACKEND_HOST</string>
  <key>AuraSplitterBackendPort</key>
  <string>$BACKEND_PORT</string>
</dict>
</plist>
PLIST

start_backend() {
  # Detached backend inherits a minimal PATH when launched from some contexts
  # (GUI / setsid). Prepend Homebrew so ffmpeg/ffprobe are always found.
  local backend_path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  if [[ -n "${PATH:-}" ]]; then
    backend_path="$backend_path:$PATH"
  fi

  /usr/bin/perl -MPOSIX=setsid -e 'exit 0 if fork; setsid(); exec @ARGV or die $!' \
    /usr/bin/env \
    PATH="$backend_path" \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH="$RUNTIME_BACKEND:$SITE_PACKAGES" \
    KIRTAN_SPLITTER_MODEL_DIR="$RUNTIME_MODEL_DIR" \
    KIRTAN_SPLITTER_LOG_FILE="$LOG_FILE" \
    MLX_USE_FAST_SDP=1 \
    "$PYTHON_REAL" "$RUNTIME_BACKEND/server.py" \
    --model-dir "$RUNTIME_MODEL_DIR" \
    --log-file "$LOG_FILE" \
    --tcp-host "$BACKEND_HOST" \
    --tcp-port "$BACKEND_PORT" \
    >>"$APP_SUPPORT/logs/backend-launcher.out.log" \
    2>>"$APP_SUPPORT/logs/backend-launcher.err.log"

  for _ in {1..80}; do
    if /usr/bin/nc -z "$BACKEND_HOST" "$BACKEND_PORT" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "Backend did not open $BACKEND_HOST:$BACKEND_PORT" >&2
  return 1
}

open_app() {
  start_backend
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  stage)
    # Staging only (used by script/release.sh): no launch, no backend start.
    echo "Staged $APP_BUNDLE (config=$BUILD_CONFIG, version=$APP_VERSION)"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 3
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME is running from $APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|stage|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
