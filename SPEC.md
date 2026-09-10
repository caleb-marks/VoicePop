# SPEC: Port Caleb’s Voxtype + Popcorn OSD to macOS

**Audience:** Coding agent on an Apple Silicon Mac.
**Goal:** Caleb’s Linux dictation setup (Voxtype + popcorn bag HUD) working daily on Mac — personal, free, no App Store, no monetization.
**Success:** Hold CapsLock → speak → text appears at cursor in Notes, Terminal, Slack/Electron, Cursor; skinny popcorn bag appears while recording and disappears within ~100ms of release; no Wispr required.

**Revision:** v2 (2026-09-06). Every Mac-specific claim below was checked against Voxtype 1.0.1 sources (`src/hotkey_macos.rs`, `src/output/paste.rs`, `src/config/root.rs`, `src/audio/levels.rs`, `src/setup/app_bundle.rs`) and rdev 0.5.3. Do not "improve" on them from memory.

**Launch model (supersedes v2 Phase 3):** ship `/Applications/VoicePop.app` + Login Item. Do **not** install a PopcornHUD LaunchAgent or KeepAlive. Phase 3 LaunchAgent / `bin/PopcornHUD` / `.accessory` instructions below are historical.

---

## 0. Non-negotiable rules for the agent

1. **Do not ask the user questions.** Every choice below is locked. If something fails, try the listed fallback in order, log it in `NOTES.md`, and continue.
2. **Do not redesign.** Match Linux behavior and the popcorn look/physics from the reference files.
3. **Do not rewrite Voxtype.** Install upstream Voxtype; customize via config + companion HUD + cleanup script.
4. **Do not use Quickshell / QML on Mac.** Quickshell is Linux/Wayland. Recreate popcorn as a **SwiftUI/AppKit** floating panel.
5. **Do not notarize, sell, or add accounts.** Personal install only. Ad-hoc sign only if Gatekeeper blocks; prefer Homebrew Voxtype + local HUD build.
6. **Work until Definition of Done** (section 9). Commit progress to git in the project repo after each phase.
7. **Be more careful than usual:** after every phase, run the phase’s verify commands and fix failures before moving on.

---

## 1. Locked architecture

| Piece | Decision |
|-------|----------|
| Dictation engine | Upstream **Voxtype ≥ 1.0.1** via tap cask `peteonrails/voxtype/voxtype`; DMG fallback if the cask is older |
| ASR | Prefer **Parakeet** `parakeet-tdt-0.6b-v3` (matches Linux). If it fails at runtime → Whisper `small.en` |
| Hotkey | Caps Lock remapped to **Right Option** by `hidutil`; Voxtype `[hotkey] key = "RIGHTALT"`. Fallback chain in §4.3 |
| Output | Voxtype `mode = "type"` (CGEvent native typing → osascript → pbcopy). **`paste` mode is Linux-only** (wl-copy/wtype); `paste_keys` is ignored on macOS |
| Cleanup | Port `voxtype-clean` to Mac (frontmost app via `lsappinfo`, not hyprctl) |
| Popcorn HUD | **New** SwiftUI/AppKit app `PopcornHUD` watching Voxtype’s state file; heat comes from the daemon’s `audio.sock`, not a mic tap; Voxtype built-in OSD **disabled** |
| Autostart | Voxtype: `/Applications/Voxtype.app` created by `voxtype setup app-bundle` (Login Item). PopcornHUD and caps remap: LaunchAgents |
| Reference | Copy Linux `Popcorn.qml` into the repo as `reference/Popcorn.qml` (read-only reference; do not execute) |

---

## 2. Files the agent must bring / create

### 2.1 Source of truth from Linux (copy onto Mac before coding)

Copy these onto the Mac into `~/src/voxtype-mac-port/` (create that directory):

```
reference/config.toml # from ~/.config/voxtype/config.toml
reference/Popcorn.qml # from ~/.config/voxtype/osd/popcorn/Popcorn.qml
reference/voxtype-osd.toml # from ~/.config/voxtype/osd/popcorn/voxtype-osd.toml
reference/voxtype-clean # from ~/.local/bin/voxtype-clean
SPEC.md # this file
```

If the agent is already on the Mac and these are missing, recreate `config.toml` and `voxtype-clean` from sections 4–5 of this SPEC and treat the `Popcorn.qml` tunables in §6.5 as binding.

### 2.2 Project layout to create

```
~/src/voxtype-mac-port/
SPEC.md
NOTES.md # agent writes discoveries, failures, paths
reference/ # Linux copies (read-only)
scripts/
install-voxtype.sh
install-caps-remap.sh # hidutil Caps Lock→Right Option + LaunchAgent (always)
restart-voxtype.sh # pkill -x voxtype-bin; open -a Voxtype
setup-launch-agents.sh
launchagents/
com.caleb.capsremap.plist
com.caleb.popcornhud.plist
bin/
voxtype-clean # Mac port of cleanup
PopcornHUD # built release binary (copied here by §6.7)
config/
config.toml # final Mac Voxtype config (install to ~/.config/voxtype/)
PopcornHUD/ # SwiftPM executable
Package.swift
Sources/...
README.md # how Caleb runs it day-to-day
```

---

## 3. Phase 0 — Machine bootstrap (do first, no UI)

**Commands (run all):**

```bash
uname -m # must be arm64; if not, still proceed but note Intel risk in NOTES.md
sw_vers
xcode-select -p || xcode-select --install
brew --version || /bin/bash -c "$(curl -fsSL https://www.google.com/url?q=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh&source=gmail&ust=1788811673163000&sa=E)"
```

**Install Voxtype:**

```bash
brew tap peteonrails/voxtype
brew install --cask peteonrails/voxtype/voxtype
voxtype --version
# Require >= 1.0.1. The tap cask has lagged behind releases (it pinned 0.7.5 while 1.0.1
# was current). Pre-1.0 builds use ~/Library/Application Support for config and an older
# state contract, which breaks this SPEC. If the version is older:
# 1. download voxtype-1.0.1-macos-universal.dmg from
# https://www.google.com/url?q=https://github.com/peteonrails/voxtype/releases&source=gmail&ust=1788811673163000&sa=E
# 2. hdiutil attach it, copy the `voxtype` binary to /opt/homebrew/bin/voxtype
# 3. xattr -dr com.apple.quarantine /opt/homebrew/bin/voxtype
# 4. voxtype --version (must print 1.0.1 or newer); log what you did in NOTES.md
voxtype setup --download --model parakeet-tdt-0.6b-v3
voxtype setup --download --model small.en
voxtype setup check
voxtype info engines
voxtype info models
```

**Runtime paths (write into NOTES.md):**

```bash
# Voxtype's runtime dir is $XDG_RUNTIME_DIR/voxtype, falling back to /tmp/voxtype.
# macOS never sets XDG_RUNTIME_DIR. Do not export it anywhere (shell, plist, HUD).
STATE_PATH=/tmp/voxtype/state
AUDIO_SOCK=/tmp/voxtype/audio.sock
voxtype config # prints the resolved config; confirm it read ~/.config/voxtype/config.toml
```

Lock `STATE_PATH=/tmp/voxtype/state` and `AUDIO_SOCK=/tmp/voxtype/audio.sock` in NOTES.md. Values written to the state file: `idle`, `recording`, `transcribing`, `streaming`. The file is deleted when the daemon exits, so a missing file means "not running / not hot".

**Permissions (agent cannot click TCC — print exact steps into README.md and NOTES.md, then continue building):**

1. Run `voxtype setup app-bundle` first (§4.4) so the grantee is **Voxtype** (`/Applications/Voxtype.app`), not Terminal.
2. System Settings → Privacy & Security → **Accessibility** → add and enable Voxtype.
3. **Input Monitoring** → add and enable Voxtype. This is required for the key listener, not optional.
4. **Microphone** → enable Voxtype after the first recording attempt.
5. PopcornHUD needs no permissions.
6. After any `brew upgrade voxtype`, rerun `voxtype setup app-bundle`; it resets the TCC entries, so steps 2–4 repeat.
7. Never run the daemon from a Terminal window for real use: the TCC identity becomes Terminal, not Voxtype.

---

## 4. Phase 1 — Voxtype config (Mac)

### 4.1 Install config

Write `~/src/voxtype-mac-port/config/config.toml` then:

```bash
mkdir -p ~/.config/voxtype
cp ~/src/voxtype-mac-port/config/config.toml ~/.config/voxtype/config.toml
```

### 4.2 Exact config contents (use this; adapt only paths)

```toml
state_file = "auto"

engine = "parakeet"

[parakeet]
model = "parakeet-tdt-0.6b-v3"

[hotkey]
enabled = true
key = "RIGHTALT" # Caps Lock is remapped to Right Option by hidutil (§4.3)
mode = "push_to_talk"
cancel_key = "ESC" # global under rdev: Escape in any app cancels an in-flight recording/transcription

[audio]
device = "default"
sample_rate = 16000
max_duration_secs = 60
pause_media = false # MPRIS/playerctl features; Linux-only
duck_media = false

[audio.feedback]
enabled = true
theme = "subtle"

[whisper]
model = "small.en"
language = "en"
translate = false
flash_attention = true
context_window_optimization = true

[output]
mode = "type" # macOS chain: CGEvent Unicode typing -> osascript -> pbcopy
fallback_to_clipboard = true
type_delay_ms = 1
pre_type_delay_ms = 1
shift_enter_newlines = false

[output.notification]
on_recording_start = false
on_recording_stop = false
on_transcription = false

[output.post_process]
command = "/Users/REPLACE_USERNAME/src/voxtype-mac-port/bin/voxtype-clean"
timeout_ms = 5000

[vad]
enabled = true
backend = "energy"

[text]
spoken_punctuation = true
smart_auto_submit = true

# PopcornHUD replaces the built-in OSD. `frontend` must stay a valid enum
# (gtk4 | native | quickshell) or be omitted; never set it to "none".
[osd]
enabled = false
```

**Agent must:** replace `REPLACE_USERNAME` with the `whoami` home path.
Never set `[osd] frontend = "none"`; it is a parse error that stops the daemon.
Do not add `paste_keys` or `wait_for_modifier_release`; neither does anything on macOS.
If `engine = "parakeet"` fails at runtime → set `engine = "whisper"` and keep `[whisper] model = "small.en"`. Log in NOTES.md.
Every `[hotkey]`, `[output]`, `[osd]` change needs `scripts/restart-voxtype.sh`.

If a stray "use_default" dialog appears when recording starts, set `[audio.feedback] enabled = false` and log it.

### 4.3 CapsLock chain (execute in order until PTT works)

Facts (verified in `src/hotkey_macos.rs` and rdev 0.5.3): `key = "CAPSLOCK"` never produces a release event on macOS, so recording would not stop; `key = "F18"` is not in Voxtype’s Mac key parser (F1–F12 only) and rdev has no F13+ keycodes. **Do not try either.** Modifier keys work.

1. **Always** install the remap Caps Lock → Right Option via `scripts/install-caps-remap.sh`, which runs the command now and installs `~/Library/LaunchAgents/com.caleb.capsremap.plist` (RunAtLoad, runs the same command at login):

```bash
/usr/bin/hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x7000000E6}]}'
hidutil property --get UserKeyMapping # must show the pair
```

Config: `key = "RIGHTALT"`. Side effect to document: the physical Right Option key is also PTT, and Caps Lock no longer toggles caps.

2. If holding Caps Lock does not flip `/tmp/voxtype/state` to `recording`: set `key = "FN"` and in System Settings → Keyboard set "Press 🌐 key to: Do Nothing". Restart the daemon. Log it.

3. If still broken: `brew install --cask hammerspoon`; change the remap target to F18 (`HIDKeyboardModifierMappingDst: 0x70000006D`); set `[hotkey] enabled = false`; run `voxtype setup hammerspoon --install --hotkey f18`; add the printed snippet to `~/.hammerspoon/init.lua`; reload Hammerspoon; grant Hammerspoon Accessibility. Log the final key in NOTES.md and README.md.

### 4.4 Start daemon at login

The cask installs a bare CLI binary, not an app. Do **not** write a LaunchAgent for Voxtype: a launchd-run bare binary does not get microphone access (upstream `app_bundle.rs`). Use the supported path:

```bash
voxtype setup app-bundle # creates /Applications/Voxtype.app (io.voxtype.daemon), adds Login Item, launches it
voxtype setup app-bundle --status
pgrep -fl Voxtype.app
```

Restart after config changes: `scripts/restart-voxtype.sh` = `pkill -x voxtype-bin; sleep 1; open -a Voxtype`.
Debug logs without breaking TCC identity: `open -a Voxtype --stdout /tmp/vt.out --stderr /tmp/vt.err --args -vv daemon`.

**Verify Phase 1:**

```bash
scripts/restart-voxtype.sh
sleep 2; voxtype status # idle
ls -la /tmp/voxtype/state /tmp/voxtype/audio.sock
# Hold Caps Lock; in another terminal: cat /tmp/voxtype/state -> recording
# Release; cat again -> transcribing, then idle
# Dictate once into TextEdit: text appears
voxtype config get hotkey.key # RIGHTALT
```

---

## 5. Phase 2 — Mac `voxtype-clean`

Write `~/src/voxtype-mac-port/bin/voxtype-clean` (executable `chmod +x`).

Behavior must match Linux:

- Read stdin → write cleaned stdout.
- Never swallow text on failure (always print original on error).
- Collapse whitespace; strip spaces before punctuation.
- Capitalize first letter unless frontmost app is a terminal.

**Frontmost app detection (Mac):** `lsappinfo` needs no Automation permission and is fast; osascript is the fallback.

```bash
app=$(/usr/bin/lsappinfo info -only name "$(/usr/bin/lsappinfo front)" 2>/dev/null | sed -E 's/.*"LSDisplayName"="([^"]*)".*/\1/')
[[ -z "$app" ]] && app=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
[[ -n "$VOXTYPE_CLEAN_APP" ]] && app="$VOXTYPE_CLEAN_APP" # test override
```

Terminal set (case-insensitive contains): `Terminal`, `iTerm`, `Alacritty`, `kitty`, `Ghostty`, `Warp`, `WezTerm` → verbatim (no auto-capitalization). Cursor and VS Code are prose (capitalize). Unknown or empty app is prose.

The daemon runs this script via `sh -c` from a Login Item with a minimal PATH: call `/usr/bin/python3` by absolute path. Do **not** call hyprctl or jq-on-hyprland JSON.

Point `[output.post_process] command` at this script’s absolute path.

**Verify:**

```bash
echo 'hello world ,' | VOXTYPE_CLEAN_APP=TextEdit bin/voxtype-clean # Hello world,
echo 'hello world ,' | VOXTYPE_CLEAN_APP=Terminal bin/voxtype-clean # hello world,
```

(Without the override, running from a terminal yields the lowercase form by design.)

---

## 6. Phase 3 — PopcornHUD (SwiftUI/AppKit) — REQUIRED

### 6.1 Why

Linux popcorn is Quickshell QML. On Mac, build **PopcornHUD**: a borderless, non-activating floating panel.

### 6.2 App requirements

- SwiftPM executable target, macOS 13+, AppKit + SwiftUI. In `main`: `NSApplication.shared.setActivationPolicy(.accessory)` (no Dock icon; no Info.plist needed).
- Bundle-free; no permissions requested.
- Window: `NSPanel` with `styleMask = [.borderless, .nonactivatingPanel]`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `ignoresMouseEvents = true`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`. Show with `orderFrontRegardless()`; never call `makeKey`.
- Position: bottom-center of `NSScreen.main ?? NSScreen.screens[0]`, origin y = `visibleFrame.minY + 40` (`margin_px = 40`), recomputed on every show.
- Content size: **240×340** (match reference `cardW`/`cardH`).
- Launch at login via `~/Library/LaunchAgents/com.caleb.popcornhud.plist`: Label `com.caleb.popcornhud`, ProgramArguments = absolute path to `~/src/voxtype-mac-port/bin/PopcornHUD`, RunAtLoad true, KeepAlive true, ProcessType Interactive, LimitLoadToSessionType Aqua.

### 6.3 State wiring

- Poll `STATE_PATH` (`/tmp/voxtype/state`) every **20 ms** (stat + read; a missing file means not hot).
- Map states:
- `recording` / `streaming` → **hot** (show bag, run sim)
- `transcribing` / `idle` / missing file → **not hot** (start exit)
- Lifecycle (match Popcorn.qml):
- Enter hot: opacity 0→1 over **110 ms**, scale 0.90→1.0 over **170 ms**, anchored bottom-center (QML `enterAnim`)
- Leave hot: clear **new** pop spawns; keep existing airborne puffs animating; opacity → 0 over **70 ms**; then reset all
- Never stay visible for the entire transcription wait
- Label: "Recording" for `recording`, "Streaming" for `streaming`; keep the last hot label through the exit fade.

### 6.4 Audio / heat (reactivity)

The daemon already broadcasts audio levels for its OSD, regardless of `[osd] enabled`. Use that; it is the same source the Linux popcorn reads.

- Connect to `AUDIO_SOCK` (`/tmp/voxtype/audio.sock`, a Unix stream socket) on a background thread whenever the state is hot; reconnect every 250 ms on failure; disconnect when not hot.
- Each frame is **16 bytes, native byte order**: `seq: UInt32, min: Float32, max: Float32, peak_dbfs: Float32`. 100 Hz, emitted only while recording.
- `peak = min(1, max(|min|, |max|))`. This is exactly the value Linux popcorn receives from `voxtype-audio-bridge`, so the constants below stay valid.
- Keep the **maximum** peak since the last sim tick (`_peakSinceTick`), reset after use. Read promptly: the daemon drops a subscriber that lags 300 ms.
- Do **not** open `AVAudioEngine` or request microphone access.
- Synthetic heat (`target = 0.35 + 0.25*sin(phase*8)` plus bursts every 0.3–0.8 s) is only the fallback when the socket is absent 2 s after going hot, and must be logged as "synthetic heat" in NOTES.md.

Heat mapping (copy Linux):

- `quietPeak = 0.015`, `loudPeak = 0.30`, `heatCurve = 0.65`
- `heat = pow(clamp((peak-quiet)/(loud-quiet),0,1), heatCurve)`
- Attack rate 28, release rate 4 (exponential approach: `v += (t-v)*(1-exp(-rate*dt))`)

### 6.5 Visual / physics — copy these tunables exactly

From `reference/Popcorn.qml`:

**Palette:**
`puffCream #F7EDD3`, `puffButter #F0BE4B`, `puffShade #B98A4B`, `heatGlow #D98324`, `bagRed #C6362F`, `bagCream #F3E3C3`

**Bag:**
`cardW 240`, `cardH 340`, `bagH 158`, `mouthHalf 58`, `baseHalf 44`, `baseCorner 9`, `sidePinch 3`, `toothCount 10`, `toothH 5`, `stripeCount 9`, `badgeW 88`, `badgeH 28`

**Physics:**
`maxPopsPerSec 90`, `simmerPopsPerSec 2`, `burstGain 40`, `minLaunch 200`, `launchRange 250`, `gravity 950`, `spreadPxPerSec 150`, `maxPuffs 120`, `targetFps 60`, `bounceChance 0.5`, `kickStiffness 420`, `kickDamping 14`, `kickPerAttack 9`

**Draw order:** bag body (cream) → fanned red/cream stripes clipped to bag path → shade → serrated mouth → overflow heap (bob while hot) → heat haze → live puffs. **No frosted glass rectangle.**

**Bag shape:** skinny tapered concession bag, pinched sides, serrated top, oval “Recording” badge on lower face (cream fill, red outline, red text). Label stays on last hot label during exit fade.

**Heap:** seed all **17** mound pieces from the QML `_resetHeap` specs, copied verbatim (same dx/dy/s/far). Bob ±1.6px with phase while hot.

**Implement with:** SwiftUI `Canvas` redrawn from a 60 Hz `DispatchSourceTimer` tick (or `TimelineView(.animation)` paced to 60), CoreGraphics paths.

### 6.6 Disable conflicts

- Voxtype OSD off (`[osd] enabled = false`, §4.2).
- PopcornHUD must not steal key focus (nonactivating panel, never `makeKey`).
- PopcornHUD must not register a global hotkey or open the microphone.

### 6.7 Build & run

```bash
cd ~/src/voxtype-mac-port/PopcornHUD
swift build -c release
cp .build/release/PopcornHUD ~/src/voxtype-mac-port/bin/PopcornHUD # no /usr/local, no sudo
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.caleb.popcornhud.plist
launchctl kickstart -k gui/$(id -u)/com.caleb.popcornhud
```

**Verify Phase 3:** Caps Lock PTT → bag appears bottom-center → popcorn reacts to voice → release → bag gone ≤100 ms → text appears in frontmost app. PopcornHUD stderr shows "audio connected" during the recording.

---

## 7. Phase 4 — Integration scripts

### `scripts/install-voxtype.sh`

Idempotent: tap + cask install, version gate (≥1.0.1), model downloads, copy config, chmod clean script, `voxtype setup app-bundle`, print TCC checklist.

### `scripts/install-caps-remap.sh`

Runs the hidutil command from §4.3 now and installs `launchagents/com.caleb.capsremap.plist` (RunAtLoad) so it reapplies at login.

### `scripts/restart-voxtype.sh`

`pkill -x voxtype-bin; sleep 1; open -a Voxtype`.

### `scripts/setup-launch-agents.sh`

Installs the caps-remap and PopcornHUD LaunchAgents with `launchctl bootstrap gui/$(id -u) <plist>` (fall back to `launchctl load` on failure), then `launchctl kickstart -k` each. Voxtype itself is a Login Item, not a LaunchAgent.

### `README.md` (for Caleb)

Must include:

1. One-time: run install scripts.
2. Grant Accessibility + Input Monitoring + Microphone to **Voxtype** (the app bundle). PopcornHUD needs nothing.
3. Caps Lock is now Right Option system-wide; the physical Right Option key is also PTT. If an external keyboard is plugged in and Caps stops working: `launchctl kickstart -k gui/$(id -u)/com.caleb.capsremap`.
4. Daily use: just hold Caps Lock (or the documented fallback key). Escape cancels.
5. After `brew upgrade voxtype`: rerun `voxtype setup app-bundle` and re-grant permissions.
6. Where NOTES.md records the final hotkey, STATE_PATH and AUDIO_SOCK.

---

## 8. What NOT to do

- No App Store submission, notarization pipeline (unless Gatekeeper blocks running; then ad-hoc sign PopcornHUD only).
- No Wispr clone features (command mode, cloud rewrite, accounts).
- No Quickshell, no Electron, no DMG productization.
- No second ASR daemon, no second microphone capture.
- No LaunchAgent for Voxtype (use the app bundle + Login Item).
- No reading VoiceInk source (GPL). Handy/Voxtype docs OK.

---

## 9. Definition of Done (all must pass)

Agent runs this checklist and pastes results into NOTES.md:

| # | Test | Pass criteria |
|---|------|----------------|
| 1 | `voxtype --version` | Prints 1.0.1 or newer |
| 2 | Config path | `diff config/config.toml ~/.config/voxtype/config.toml` is empty; `voxtype config get hotkey.key` prints `RIGHTALT` (or the documented fallback) |
| 3 | State file | `/tmp/voxtype/state` changes `idle→recording→transcribing→idle` on one dictation |
| 4 | TextEdit typing | Spoken sentence appears at cursor |
| 5 | Terminal typing | Spoken sentence appears (Ghostty/Terminal/iTerm — whichever installed), not capitalized |
| 6 | Cursor or VS Code typing | Spoken sentence appears in the editor and in its integrated terminal |
| 7 | Popcorn visible | Bag shows within 200 ms of PTT down |
| 8 | Popcorn exit | Bag fully gone within 100 ms of PTT up (do not wait for transcription) |
| 9 | No glass panel | Screenshot description: only bag + popcorn, transparent chrome |
| 10 | Cleanup | `echo 'hi ,' \| VOXTYPE_CLEAN_APP=TextEdit bin/voxtype-clean` → `Hi,` |
| 11 | Restart persistence | `pkill -x voxtype-bin; open -a Voxtype` brings the daemon back; `launchctl kickstart -k gui/$(id -u)/com.caleb.popcornhud` brings the HUD back; Login Item and both LaunchAgents are listed. Real logout/login is Caleb’s manual check |
| 12 | Audio feed | `/tmp/voxtype/audio.sock` exists and PopcornHUD logs "audio connected" during a recording |

---

## 10. Execution order (agent checklist)

Copy this and tick in NOTES.md:

- [ ] Phase 0 bootstrap + Voxtype ≥1.0.1 + models + NOTES.md STATE_PATH/AUDIO_SOCK
- [ ] Phase 1 config.toml installed + app bundle running + hidutil remap installed + RIGHTALT verified
- [ ] Phase 2 voxtype-clean working
- [ ] Phase 3 PopcornHUD builds, LaunchAgent loaded, visual match, audio.sock connected
- [ ] Phase 4 scripts + README
- [ ] Section 9 DoD all green

**Start now at Phase 0. Do not wait for confirmation.**
</user_query>