#!/bin/bash
# Clear Caps Lock → Right Option hidutil mapping and remove LaunchAgent.
set -euo pipefail

PLIST_DST="$HOME/Library/LaunchAgents/com.caleb.capsremap.plist"
LABEL="com.caleb.capsremap"
UID_NUM="$(id -u)"

echo "==> Clearing UserKeyMapping"
/usr/bin/hidutil property --set '{"UserKeyMapping":[]}'
/usr/bin/hidutil property --get UserKeyMapping

echo "==> Removing LaunchAgent $LABEL"
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl unload "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST"
echo "OK: Caps Lock remapping removed"
