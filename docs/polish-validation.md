# VoicePop 1.2.0 local installation validation

Validated September 12, 2026 on this Apple Silicon Mac.

## Changes integrated

- Cinema-red tub, buttery kernel artwork, fuller connected pile motion, and cached rendering.
- Native Settings, appearance preview, learned-word editor, correction recovery, and setup checklist.
- Event-driven state observation, bounded process operations, and recovery reporting.
- Pending Settings review fixes merged, including login-toggle safety, full preview geometry, save errors, and learned-word merge protection.
- Final fixes preserve the open correction editor on repeated requests, report Settings model downloads to health, prevent overlapping model switches, disable blocked recording commands, and remove duplicate menu separators.
- Daemon PID validation now checks the executable identity; release verification supports app-only ZIPs.

## Checks passed

- 153 Swift tests, zero failures; debug and release builds succeeded.
- Isolated UI harness rendered 24 light/dark snapshots. Appearance preview and General layout inspected. Native-size light/dark popcorn renders inspected; 790-frame motion artifacts generated.
- Fixture assertions verify reopening a correction preserves edited text and learned-word edits preserve concurrent additions and refuse newly malformed files.
- Fresh Developer ID-signed ZIP and DMG passed required-content, absolute-home-path, and deep strict signature checks.
- Installed app and previous engine configuration were backed up. Configuration now runs `/Applications/VoicePop.app/Contents/MacOS/voxtype-clean`.
- Installed build started the engine and reached idle. A real start/cancel cycle produced 67 HUD draw events, returned to idle, and stopped rendering while hidden. No text was inserted by that test.

## Remaining manual checks

- FN-key speech-to-text insertion in a real text field, VoiceOver announcements, and full interactive Settings navigation. The computer-use service timed out, so these are not claimed as verified.
- Actual logout/login, multiple monitors, microphone device changes, and testing on macOS 13.
- These local 1.2.0 artifacts are signed but have not been notarized or published. The separate 1.1.3 notarization submission does not cover this build.
- The temporary polish specification remains available while these acceptance checks are outstanding.

## Local evidence

Artifacts are under `/Users/builder/VoicePop-polish/artifacts/`:

- `finish-tests.log`, `finish-package.log`, `finish-release-verification.log`
- `finish-ui/`, `finish-art/`, `finish-motion/`
- `finish-install-result.json`, `finish-recording-result.json`, `finish-installed.log`
- `installed-backup-20260912-203910/VoicePop.app` and `voxtype-config.toml`

Signed archives are under `/Users/builder/VoicePop-polish/finish/dist/`.
