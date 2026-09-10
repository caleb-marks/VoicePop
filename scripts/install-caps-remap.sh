#!/bin/bash
# Remap Caps Lock → Right Option and install LaunchAgent to reapply at login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_SRC="$ROOT/launchagents/com.caleb.capsremap.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.caleb.capsremap.plist"
LABEL="com.caleb.capsremap"
UID_NUM="$(id -u)"

HIDUTIL_JSON='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x7000000E6}]}'

echo "==> Applying Caps Lock → Right Option now"
/usr/bin/hidutil property --set "$HIDUTIL_JSON"
/usr/bin/hidutil property --get UserKeyMapping

echo "==> Installing LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"

# Prefer bootstrap; fall back to load
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
if ! launchctl bootstrap "gui/${UID_NUM}" "$PLIST_DST" 2>/dev/null; then
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  launchctl load "$PLIST_DST"
fi
launchctl kickstart -k "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
echo "OK: Caps remap LaunchAgent installed"
