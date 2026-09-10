#!/bin/bash
# Install VoicePop.app (replaces the old PopcornHUD LaunchAgent).
# Voxtype remains a separate Login Item via `voxtype setup app-bundle`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UID_NUM="$(id -u)"
LABEL="com.caleb.popcornhud"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DEST="/Applications/VoicePop.app"

echo "==> Packaging VoicePop.app"
"$ROOT/scripts/package-app.sh"

echo "==> Removing LaunchAgent $LABEL"
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
if [[ -f "$PLIST" ]]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
fi

echo "==> Stopping leftover HUD processes"
pkill -x VoicePop 2>/dev/null || true
pkill -x PopcornHUD 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! pgrep -x VoicePop >/dev/null && ! pgrep -x PopcornHUD >/dev/null; then
    break
  fi
  sleep 0.2
done
if pgrep -x VoicePop >/dev/null || pgrep -x PopcornHUD >/dev/null; then
  pkill -9 -x VoicePop 2>/dev/null || true
  pkill -9 -x PopcornHUD 2>/dev/null || true
  sleep 0.2
fi

echo "==> Installing $DEST"
rm -rf "$DEST"
cp -R "$ROOT/dist/VoicePop.app" "$DEST"

echo "==> Launching VoicePop"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true
open "$DEST"

echo "OK: VoicePop.app installed. Login Item registers on first /Applications launch."
echo "    Quit from the menu bar stays quit until next login or you open the app again."
echo "    If Dock/Finder still show the old icon: killall Dock"
