#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
# Binary/process name (SwiftPM executable).
APP_NAME="AuraSplitter"
# User-visible brand folders (models, logs, App Support).
BRAND_NAME="AuraSplitter"
LEGACY_BRAND_NAME="KirtanSplitter"
BUNDLE_ID="com.pavan.aurasplitter"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
PYTHON_REAL="$(realpath "$ROOT_DIR/.venv/bin/python")"
SITE_PACKAGES="$ROOT_DIR/.venv/lib/python3.11/site-packages"
BACKEND_HOST="127.0.0.1"
BACKEND_PORT="${KIRTAN_SPLITTER_BACKEND_PORT:-51273}"
BACKEND_LABEL="com.pavan.aurasplitter.backend"

cd "$ROOT_DIR"

if [[ ! -x "$ROOT_DIR/.venv/bin/python" ]]; then
  "$ROOT_DIR/script/setup_backend.sh"
fi

# Kill legacy KirtanSplitter processes too
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "KirtanSplitter" >/dev/null 2>&1 || true
launchctl remove "$BACKEND_LABEL" >/dev/null 2>&1 || true
launchctl remove "com.pavan.kirtansplitter.backend" >/dev/null 2>&1 || true
pkill -f "$ROOT_DIR/backend/server.py" >/dev/null 2>&1 || true
pkill -f "$ROOT_DIR/script/run_backend.sh" >/dev/null 2>&1 || true
pkill -f "$APP_SUPPORT/backend/server.py" >/dev/null 2>&1 || true
pkill -f "$APP_SUPPORT/run_backend.sh" >/dev/null 2>&1 || true
pkill -f "$LEGACY_APP_SUPPORT/backend/server.py" >/dev/null 2>&1 || true
pkill -f "$LEGACY_APP_SUPPORT/run_backend.sh" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

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
# App icon (.icns for dock)
if [[ -f "$ROOT_DIR/LOGO/AuraSplitter.svg" ]]; then
  cp "$ROOT_DIR/LOGO/AuraSplitter.svg" "$APP_RESOURCES/AuraSplitter.svg"
  "$ROOT_DIR/script/make_app_icon.sh" "$ROOT_DIR/LOGO/AuraSplitter.svg" "$APP_RESOURCES/AuraSplitter.icns"
fi
# Color logo for in-app header
if [[ -f "$ROOT_DIR/LOGO/AuraSplitter_2.svg" ]]; then
  cp "$ROOT_DIR/LOGO/AuraSplitter_2.svg" "$APP_RESOURCES/AuraSplitter_Color.svg"
fi
# White logo for menu bar tray icon
if [[ -f "$ROOT_DIR/LOGO/AuraSplitter_White.svg" ]]; then
  cp "$ROOT_DIR/LOGO/AuraSplitter_White.svg" "$APP_RESOURCES/AuraSplitter_White.svg"
fi
cp -R "$ROOT_DIR/backend" "$RUNTIME_BACKEND"
cp "$ROOT_DIR/script/run_backend.sh" "$RUNTIME_LAUNCHER"
chmod +x "$RUNTIME_LAUNCHER"
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
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>AuraSplitterProjectRoot</key>
  <string>$ROOT_DIR</string>
  <key>AuraSplitterPython</key>
  <string>$PYTHON_REAL</string>
  <key>AuraSplitterPythonPath</key>
  <string>$RUNTIME_BACKEND:$SITE_PACKAGES</string>
  <key>AuraSplitterBackendServer</key>
  <string>$RUNTIME_BACKEND/server.py</string>
  <key>AuraSplitterBackendLauncher</key>
  <string>$RUNTIME_LAUNCHER</string>
  <key>AuraSplitterModelDir</key>
  <string>$RUNTIME_MODEL_DIR</string>
  <key>AuraSplitterLogFile</key>
  <string>$LOG_FILE</string>
  <key>AuraSplitterBackendHost</key>
  <string>$BACKEND_HOST</string>
  <key>AuraSplitterBackendPort</key>
  <string>$BACKEND_PORT</string>
</dict>
</plist>
PLIST

start_backend() {
  /usr/bin/perl -MPOSIX=setsid -e 'exit 0 if fork; setsid(); exec @ARGV or die $!' \
    /usr/bin/env \
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
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
