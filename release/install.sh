#!/bin/bash
# VoicePop installer for the downloaded release zip.
# Installs Voxtype (bundled Parakeet-capable build), the Parakeet model, VoicePop.app, and a
# Voxtype config that routes dictation through VoicePop. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$HERE/VoicePop.app"
APP_DST="/Applications/VoicePop.app"
VOX_SRC="$HERE/voxtype-bin"
VOX_APP_BIN="/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"
CFG="$HOME/.config/voxtype/config.toml"
MODEL="parakeet-tdt-0.6b-v3-int8"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || die "VoicePop needs Apple Silicon (this Mac is $(uname -m))."
[[ -d "$APP_SRC" ]] || die "VoicePop.app not found next to install.sh."
[[ -f "$VOX_SRC" ]] || die "voxtype-bin not found next to install.sh."

say "Clearing quarantine on downloaded files"
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null || true
chmod +x "$VOX_SRC" "$APP_SRC/Contents/MacOS/"* "$APP_SRC/Contents/Resources/restart-voxtype.sh"

has_parakeet() {
  local out
  [[ -x "$1" ]] || return 1
  out="$("$1" info engines 2>/dev/null || true)"
  grep -q 'compiled  parakeet' <<<"$out"
}

if has_parakeet "$VOX_APP_BIN"; then
  say "Voxtype with Parakeet already installed; keeping it"
else
  say "Installing Voxtype.app (Login Item) from bundled build"
  pkill -x voxtype-bin 2>/dev/null || true
  "$VOX_SRC" setup app-bundle
  if [[ -w /opt/homebrew/bin ]]; then
    cp "$VOX_SRC" /opt/homebrew/bin/voxtype && chmod +x /opt/homebrew/bin/voxtype
    echo "    'voxtype' CLI installed to /opt/homebrew/bin"
  fi
fi
has_parakeet "$VOX_APP_BIN" || die "Voxtype install did not produce a Parakeet-capable $VOX_APP_BIN"

say "Downloading speech model $MODEL (about 2.4 GB, one time)"
"$VOX_APP_BIN" setup --download --model "$MODEL"

if [[ -f "$CFG" ]]; then
  say "Keeping existing $CFG"
  if ! grep -q "voxtype-clean" "$CFG"; then
    echo "    NOTE: it has no [output.post_process] command. Add:"
    echo "      command = \"$APP_DST/Contents/MacOS/voxtype-clean\""
  fi
else
  say "Writing $CFG"
  mkdir -p "$(dirname "$CFG")"
  sed "s|__VOICEPOP_ROOT__/bin/voxtype-clean|$APP_DST/Contents/MacOS/voxtype-clean|" \
    "$APP_SRC/Contents/Resources/config.toml" > "$CFG"
fi

say "Installing $APP_DST"
pkill -x VoicePop 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

say "Starting Voxtype and VoicePop"
"$APP_DST/Contents/Resources/restart-voxtype.sh" >/dev/null 2>&1 || open -a Voxtype
open "$APP_DST"

cat <<'TXT'

Done. Two things macOS makes you click yourself:

1. System Settings > Privacy & Security: enable Voxtype under Accessibility,
   Input Monitoring, and (after your first recording) Microphone.
   Grant these to Voxtype, not VoicePop or Terminal.
2. System Settings > Keyboard > "Press globe key to": Do Nothing.

Then hold FN, talk, release. Text appears where your cursor is.
TXT
