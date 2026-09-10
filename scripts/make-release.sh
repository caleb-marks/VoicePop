#!/bin/bash
# Build the downloadable release zip: dist/VoicePop-<version>-macos-arm64.zip
# Contents: VoicePop.app, Parakeet-capable voxtype-bin, install.sh, README.txt
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

echo "$ZIP"
shasum -a 256 "$ZIP"
