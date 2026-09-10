#!/bin/bash
# Build PopcornHUD + voxtype-clean and assemble dist/VoicePop.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/VoicePop.app"
CONTENTS="$APP/Contents"
SIGN_ID="${VOICEPOP_SIGN_IDENTITY:-}"

echo "==> Building PopcornHUD (release)"
(cd "$ROOT/PopcornHUD" && swift build -c release)

HUD="$ROOT/PopcornHUD/.build/release/PopcornHUD"
CLEAN="$ROOT/PopcornHUD/.build/release/voxtype-clean"
if [[ ! -x "$HUD" ]]; then
  echo "ERROR: missing $HUD" >&2
  exit 1
fi

echo "==> Staging companion binaries"
mkdir -p "$ROOT/bin"
rm -f "$ROOT/bin/PopcornHUD"
if [[ -x "$CLEAN" ]]; then
  cp "$CLEAN" "$ROOT/bin/voxtype-clean"
  chmod +x "$ROOT/bin/voxtype-clean"
else
  echo "WARNING: voxtype-clean not built" >&2
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/app/Info.plist" "$CONTENTS/Info.plist"
cp "$HUD" "$CONTENTS/MacOS/VoicePop"
chmod +x "$CONTENTS/MacOS/VoicePop"
cp "$ROOT/scripts/restart-voxtype.sh" "$CONTENTS/Resources/restart-voxtype.sh"
chmod +x "$CONTENTS/Resources/restart-voxtype.sh"

echo "==> App icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/generate-app-icon.swift" "$ICONSET"
iconutil -c icns -o "$CONTENTS/Resources/AppIcon.icns" "$ICONSET"

echo "==> Codesign"
xattr -cr "$APP" 2>/dev/null || true
IDENTITIES="$(security find-identity -v -p codesigning || true)"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(printf '%s\n' "$IDENTITIES" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [[ -n "$SIGN_ID" ]] && printf '%s\n' "$IDENTITIES" | grep -Fq "$SIGN_ID"; then
  codesign --force --deep --timestamp --sign "$SIGN_ID" "$APP"
else
  echo "WARN: signing identity not found: $SIGN_ID" >&2
  echo "WARN: falling back to ad-hoc. Set VOICEPOP_SIGN_IDENTITY to a valid codesign identity." >&2
  codesign --force --deep --sign - "$APP"
fi

echo "OK: $APP"
defaults read "$CONTENTS/Info" CFBundleIdentifier
