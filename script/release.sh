#!/usr/bin/env bash
# AuraSplitter release pipeline.
#
#   script/release.sh <version> [--skip-notarize] [--no-publish]
#
# Produces, for version X.Y.Z:
#   dist/AuraSplitter-X.Y.Z-arm64.dmg    — signed, notarized, stapled installer
#   dist/AuraSplitter-X.Y.Z-arm64.zip    — signed+stapled .app archive (auto-updater)
# and (unless --no-publish) publishes a GitHub Release v<X.Y.Z> with both assets.
#
# Prerequisites (one-time):
#   * "Developer ID Application" identity in the keychain (or AURA_SIGN_IDENTITY env).
#   * Notary credentials stored via:
#       xcrun notarytool store-credentials AuraSplitter \
#         --apple-id you@example.com --team-id 438UQRF7JV --password <app-specific password>
set -euo pipefail

VERSION="${1:-}"
SKIP_NOTARIZE=false
PUBLISH=true
for arg in "${@:2}"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=true ;;
    --no-publish) PUBLISH=false ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <X.Y.Z> [--skip-notarize] [--no-publish]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AuraSplitter"
DIST="$ROOT_DIR/dist"
APP="$DIST/$APP_NAME.app"
# Unversioned asset names keep releases/latest/download/ links stable.
ZIP="$DIST/$APP_NAME-arm64.zip"
DMG="$DIST/$APP_NAME-arm64.dmg"
STAPLER="xcrun stapler"
PROFILE="${AURA_NOTARY_PROFILE:-AuraSplitter}"

echo "== AuraSplitter release $VERSION =="

# 1. Version file drives CFBundleShortVersionString inside the staged bundle.
printf '%s\n' "$VERSION" > "$ROOT_DIR/VERSION"

# 2. Build + stage (release config, no launch).
BUILD_CONFIG=release "$ROOT_DIR/script/build_and_run.sh" stage

# 3. Code signing (Developer ID + hardened runtime) so Gatekeeper is satisfied.
IDENTITY="${AURA_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "ERROR: no Developer ID Application signing identity found." >&2
  echo "Install one via Xcode → Settings → Accounts, or set AURA_SIGN_IDENTITY." >&2
  exit 3
fi
echo "-- codesign: $IDENTITY"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
spctl -a -vv -t execute "$APP"

# 4. Register the app signature with Apple notary (submission #1), then staple
#    the bundle — the updater ZIP then carries a stapled app that passes
#    Gatekeeper even on offline machines.
if [[ "$SKIP_NOTARIZE" == false ]]; then
  REGISTRY_ZIP="$DIST/.registry-$VERSION.zip"
  rm -f "$REGISTRY_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$REGISTRY_ZIP"
  echo "-- notarytool register app ($PROFILE); waiting…"
  xcrun notarytool submit "$REGISTRY_ZIP" --keychain-profile "$PROFILE" --wait
  $STAPLER staple "$APP"
  rm -f "$REGISTRY_ZIP"
  spctl -a -vv -t execute "$APP"
fi

# 5. Zip archive for the auto-updater (preserves signature + staple metadata).
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# 6. DMG for humans: drag-to-Applications layout.
rm -f "$DMG"
STAGE_DMG="$(mktemp -d)/AuraSplitter-$VERSION"
mkdir -p "$STAGE_DMG"
cp -R "$APP" "$STAGE_DMG/"
ln -s /Applications "$STAGE_DMG/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE_DMG" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE_DMG")"

# 7. Notarization (Apple's service) + staple the ticket into the DMG.
if [[ "$SKIP_NOTARIZE" == true ]]; then
  echo "!! SKIPPING notarization (--skip-notarize): DMG will trigger Gatekeeper on other Macs."
else
  echo "-- notarytool submit DMG ($PROFILE); waiting…"
  if ! xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
    cat >&2 <<EOF

Notarization failed. If no credentials are stored yet, run once:

  xcrun notarytool store-credentials $PROFILE \\
    --apple-id <your-apple-id> --team-id 438UQRF7JV \\
    --password <app-specific-password>

(Or re-run with --skip-notarize for an unsigned-for-Gatekeeper build.)
EOF
    exit 4
  fi
  $STAPLER staple "$DMG"
  spctl -a -vv -t open "$DMG"
fi

echo "-- artifacts:"
ls -lh "$ZIP" "$DMG"

# 8. GitHub Release with both assets. The sha256 line in the notes is consumed
#    by the in-app updater as an additional integrity check.
if [[ "$PUBLISH" == true ]]; then
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated; cannot publish." >&2; exit 5; }
  NOTES="$(mktemp)"
  {
    echo "## AuraSplitter $VERSION"
    echo
    echo "- Install: open the DMG and drag **AuraSplitter** into Applications."
    echo "- The in-app updater uses the \`.zip\` asset."
    echo
    echo '```'
    echo "sha256($APP_NAME-$VERSION-arm64.zip) = $ZIP_SHA"
    echo '```'
  } >"$NOTES"
  gh release create "v$VERSION" "$DMG" "$ZIP" \
    --title "AuraSplitter $VERSION" \
    --notes-file "$NOTES"
  rm -f "$NOTES"
  echo "-- published release v$VERSION"
else
  echo "-- --no-publish: skipping GitHub release."
  echo "   Publish later with:"
  echo "   gh release create v$VERSION \"$DMG\" \"$ZIP\" --title \"AuraSplitter $VERSION\" --notes <file>"
fi

echo "== done =="
