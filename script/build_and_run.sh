#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="KirtanSplitter"
BUNDLE_ID="com.pavan.kirtansplitter"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_SUPPORT="$HOME/Library/Application Support/$APP_NAME"
RUNTIME_BACKEND="$APP_SUPPORT/backend"
RUNTIME_LAUNCHER="$APP_SUPPORT/run_backend.sh"
RUNTIME_MODEL_DIR="$APP_SUPPORT/models"
LOG_FILE="$APP_SUPPORT/logs/backend.log"
PYTHON_REAL="$(realpath "$ROOT_DIR/.venv/bin/python")"
SITE_PACKAGES="$ROOT_DIR/.venv/lib/python3.11/site-packages"
BACKEND_HOST="127.0.0.1"
BACKEND_PORT="${KIRTAN_SPLITTER_BACKEND_PORT:-51273}"
BACKEND_LABEL="com.pavan.kirtansplitter.backend"

cd "$ROOT_DIR"

if [[ ! -x "$ROOT_DIR/.venv/bin/python" ]]; then
  "$ROOT_DIR/script/setup_backend.sh"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
launchctl remove "$BACKEND_LABEL" >/dev/null 2>&1 || true
pkill -f "$ROOT_DIR/backend/server.py" >/dev/null 2>&1 || true
pkill -f "$ROOT_DIR/script/run_backend.sh" >/dev/null 2>&1 || true
pkill -f "$APP_SUPPORT/backend/server.py" >/dev/null 2>&1 || true
pkill -f "$APP_SUPPORT/run_backend.sh" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
rm -rf "$RUNTIME_BACKEND"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$(dirname "$LOG_FILE")" "$RUNTIME_MODEL_DIR"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp -R "$ROOT_DIR/backend" "$RUNTIME_BACKEND"
cp "$ROOT_DIR/script/run_backend.sh" "$RUNTIME_LAUNCHER"
chmod +x "$RUNTIME_LAUNCHER"
if [[ -d "$ROOT_DIR/models" ]]; then
  rsync -a --ignore-existing "$ROOT_DIR/models/" "$RUNTIME_MODEL_DIR/"
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
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>KirtanSplitterProjectRoot</key>
  <string>$ROOT_DIR</string>
  <key>KirtanSplitterPython</key>
  <string>$PYTHON_REAL</string>
  <key>KirtanSplitterPythonPath</key>
  <string>$RUNTIME_BACKEND:$SITE_PACKAGES</string>
  <key>KirtanSplitterBackendServer</key>
  <string>$RUNTIME_BACKEND/server.py</string>
  <key>KirtanSplitterBackendLauncher</key>
  <string>$RUNTIME_LAUNCHER</string>
  <key>KirtanSplitterModelDir</key>
  <string>$RUNTIME_MODEL_DIR</string>
  <key>KirtanSplitterLogFile</key>
  <string>$LOG_FILE</string>
  <key>KirtanSplitterBackendHost</key>
  <string>$BACKEND_HOST</string>
  <key>KirtanSplitterBackendPort</key>
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
