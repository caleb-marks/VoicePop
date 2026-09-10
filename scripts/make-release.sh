#!/bin/bash
# Build the downloadable release: dist/VoicePop-<version>.dmg (drag to Applications; the app
# sets itself up on first launch) plus dist/VoicePop-<version>-macos-arm64.zip (Terminal installer).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOX_BIN="${VOXTYPE_BIN:-/Applications/Voxtype.app/Contents/MacOS/voxtype-bin}"

[[ -x "$VOX_BIN" ]] || { echo "ERROR: $VOX_BIN missing (set VOXTYPE_BIN)" >&2; exit 1; }
ENGINES="$("$VOX_BIN" info engines 2>/dev/null || true)"
grep -q 'compiled  parakeet' <<<"$ENGINES" \
  || { echo "ERROR: $VOX_BIN is not a Parakeet-capable build" >&2; exit 1; }

"$ROOT/scripts/package-app.sh" >/dev/null
[[ -x "$ROOT/dist/VoicePop.app/Contents/MacOS/voxtype-clean" ]] \
  || { echo "ERROR: voxtype-clean not bundled in dist/VoicePop.app" >&2; exit 1; }

VERSION="$(defaults read "$ROOT/dist/VoicePop.app/Contents/Info" CFBundleShortVersionString)"
NAME="VoicePop-${VERSION}-macos-arm64"
STAGE="$ROOT/dist/$NAME"
ZIP="$ROOT/dist/$NAME.zip"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
cp -R "$ROOT/dist/VoicePop.app" "$STAGE/VoicePop.app"
cp "$VOX_BIN" "$STAGE/voxtype-bin"
cp "$ROOT/release/install.sh" "$ROOT/release/README.txt" "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/voxtype-bin"

codesign --verify --deep --strict "$STAGE/VoicePop.app"
ditto -c -k --keepParent "$STAGE" "$ZIP"
rm -rf "$STAGE"

DMG_ROOT="$ROOT/dist/dmg-root"
DMG="$ROOT/dist/VoicePop-${VERSION}.dmg"
rm -rf "$DMG_ROOT" "$DMG"
mkdir -p "$DMG_ROOT"
cp -R "$ROOT/dist/VoicePop.app" "$DMG_ROOT/VoicePop.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -quiet -volname "VoicePop" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
rm -rf "$DMG_ROOT"

echo "$DMG"
echo "$ZIP"
shasum -a 256 "$DMG" "$ZIP"
