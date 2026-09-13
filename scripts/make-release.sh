#!/bin/bash
# Produce a signed, notarized DMG and app-only ZIP. Never publish development builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${VOICEPOP_SIGN_IDENTITY:?Set a Developer ID Application certificate name}"
: "${VOICEPOP_NOTARY_PROFILE:?Set the notarytool keychain profile name}"
[[ "$VOICEPOP_SIGN_IDENTITY" == Developer\ ID\ Application:* ]] || { echo 'A Developer ID Application certificate is required.' >&2; exit 1; }
security find-identity -v -p codesigning | grep -Fq "\"$VOICEPOP_SIGN_IDENTITY\"" || { echo 'Signing certificate unavailable.' >&2; exit 1; }
VOX_BIN="${VOXTYPE_BIN:-/Applications/Voxtype.app/Contents/MacOS/voxtype-bin}"
VOX_PROVENANCE="${VOXTYPE_PROVENANCE:-$(dirname "$VOX_BIN")/VOXTYPE-BUILD.txt}"
[[ -x "$VOX_BIN" ]] || { echo 'Set VOXTYPE_BIN to the Parakeet engine.' >&2; exit 1; }
[[ -f "$VOX_PROVENANCE" ]] \
  || { echo "ERROR: $VOX_PROVENANCE missing (set VOXTYPE_PROVENANCE)" >&2; exit 1; }
"$VOX_BIN" info engines | grep -q 'compiled  parakeet'
VOXTYPE_BIN="$VOX_BIN" VOXTYPE_PROVENANCE="$VOX_PROVENANCE" "$ROOT/scripts/package-app.sh"
APP="$ROOT/dist/VoicePop.app"
HELPER="$APP/Contents/Helpers/Voxtype.app"
[[ -x "$HELPER/Contents/MacOS/voxtype-bin" ]]
[[ -f "$APP/Contents/Resources/VOXTYPE-BUILD.txt" ]]
notarize() {
  local artifact="$1" result="$2" status
  xcrun notarytool submit "$artifact" --keychain-profile "$VOICEPOP_NOTARY_PROFILE" --wait --output-format json > "$result"
  status="$(plutil -extract status raw -o - "$result")"
  [[ "$status" == Accepted ]] || { echo "Notarization was $status. See $result; use notarytool log with its submission id." >&2; exit 1; }
}
# One submission covers the signed app and its nested helper. Stapling tickets
# does not require re-signing; preserve the code signatures Apple inspected.
ditto -c -k --keepParent "$APP" "$ROOT/dist/notary-app.zip"
notarize "$ROOT/dist/notary-app.zip" "$ROOT/dist/notary-app.json"
xcrun stapler staple "$HELPER"
xcrun stapler validate "$HELPER"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$HELPER"
VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
STAGE="$(mktemp -d "$ROOT/dist/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/VoicePop.app"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/dist/VoicePop-${VERSION}.dmg"
hdiutil create -quiet -volname VoicePop -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$VOICEPOP_SIGN_IDENTITY" "$DMG"
notarize "$DMG" "$ROOT/dist/notary-dmg.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
cp "$DMG" "$ROOT/dist/VoicePop.dmg"
ZIP="$ROOT/dist/VoicePop-${VERSION}-macos-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "VoicePop-${VERSION}.dmg" VoicePop.dmg "VoicePop-${VERSION}-macos-arm64.zip" > SHA256SUMS)
echo "Verified release assets: $DMG, $ZIP, dist/VoicePop.dmg, dist/SHA256SUMS"
