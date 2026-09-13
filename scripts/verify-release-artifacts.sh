#!/bin/bash
# Verify release contents and reject accidental local-path or secret disclosure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(defaults read "$ROOT/app/Info" CFBundleShortVersionString)"
ZIP="$ROOT/dist/VoicePop-${VERSION}-macos-arm64.zip"
DMG="$ROOT/dist/VoicePop-${VERSION}.dmg"
WORK="$(mktemp -d)"
MOUNT="$WORK/dmg"
DEVICE=""
cleanup() {
  if [[ -n "$DEVICE" ]]; then hdiutil detach -quiet "$DEVICE" || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

[[ -f "$ZIP" && -f "$DMG" ]] || { echo "ERROR: expected release artifacts are missing" >&2; exit 1; }
ditto -x -k "$ZIP" "$WORK/zip"
verify_app_contents() {
  local app="$1" label="$2" item
  for item in VOICEPOP-LICENSE VOXTYPE-LICENSE VOXTYPE-BUILD.txt; do
    test -f "$app/Contents/Resources/$item" \
      || { echo "ERROR: $label app is missing $item" >&2; exit 1; }
  done
  for item in MacOS/VoicePop MacOS/voxtype-clean Helpers/Voxtype.app/Contents/MacOS/voxtype-bin; do
    test -x "$app/Contents/$item" \
      || { echo "ERROR: $label app is missing executable $item" >&2; exit 1; }
  done
}
verify_app_contents "$WORK/zip/VoicePop.app" ZIP

mkdir -p "$MOUNT"
DEVICE="$(hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" | tail -1 | awk '{print $1}')"
[[ -n "$DEVICE" ]] || { echo "ERROR: could not identify mounted DMG device" >&2; exit 1; }
verify_app_contents "$MOUNT/VoicePop.app" DMG

find "$WORK/zip" "$MOUNT" -type f -perm -111 -print0 | while IFS= read -r -d '' binary; do
  if strings "$binary" \
      | grep -E '/Users/|/home/' \
      | grep -vF '/Users/runner/work/ort-artifacts/' >/dev/null; then
    echo "ERROR: executable contains an absolute user home path: $binary" >&2
    exit 1
  fi
done

codesign --verify --deep --strict "$WORK/zip/VoicePop.app"
codesign --verify --deep --strict "$MOUNT/VoicePop.app"
echo "Release artifacts passed content, path, and signature checks."
shasum -a 256 "$DMG" "$ZIP"
