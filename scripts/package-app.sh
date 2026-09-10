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
# Bundled copies so a downloaded VoicePop.app is self-contained (install.sh points Voxtype at them).
if [[ -x "$ROOT/bin/voxtype-clean" ]]; then
  cp "$ROOT/bin/voxtype-clean" "$CONTENTS/MacOS/voxtype-clean"
  chmod +x "$CONTENTS/MacOS/voxtype-clean"
fi
cp "$ROOT/config/config.toml" "$CONTENTS/Resources/config.toml"
VOX_SRC="${VOXTYPE_BIN:-/Applications/Voxtype.app/Contents/MacOS/voxtype-bin}"
VOX_ENGINES="$( [[ -x "$VOX_SRC" ]] && "$VOX_SRC" info engines 2>/dev/null || true )"
if grep -q 'compiled  parakeet' <<<"$VOX_ENGINES"; then
  cp "$VOX_SRC" "$CONTENTS/Resources/voxtype-bin"
  chmod +x "$CONTENTS/Resources/voxtype-bin"
else
  echo "WARNING: no Parakeet-capable voxtype-bin at $VOX_SRC; app will not be able to self-install Voxtype (set VOXTYPE_BIN)" >&2
fi

echo "==> App icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/generate-app-icon.swift" "$ICONSET"
iconutil -c icns -o "$CONTENTS/Resources/AppIcon.icns" "$ICONSET"

echo "==> Codesign"
xattr -cr "$APP" 2>/dev/null || true
# Ad-hoc by default. An Apple Development certificate embeds the Apple ID email in its common
# name, which then ships inside every published binary, so never auto-select one. Set
# VOICEPOP_SIGN_IDENTITY to a Developer ID identity to sign for distribution.
if [[ -n "$SIGN_ID" && "$SIGN_ID" != "-" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning || true)"
  if ! printf '%s\n' "$IDENTITIES" | grep -Fq "$SIGN_ID"; then
    echo "ERROR: signing identity not found in keychain: $SIGN_ID" >&2
    exit 1
  fi
  if [[ "$SIGN_ID" == Apple\ Development:* ]]; then
    echo "ERROR: refusing to sign a release with an Apple Development identity (embeds the Apple ID email). Use a Developer ID identity or leave VOICEPOP_SIGN_IDENTITY unset for ad-hoc." >&2
    exit 1
  fi
  codesign --force --deep --timestamp --sign "$SIGN_ID" "$APP"
else
  echo "==> Ad-hoc signature (set VOICEPOP_SIGN_IDENTITY to a Developer ID identity to sign for distribution)"
  codesign --force --deep --sign - "$APP"
fi

echo "OK: $APP"
defaults read "$CONTENTS/Info" CFBundleIdentifier
