# Voxtype Mac Port — Agent Notes

**Project root:** `~/VoicePop` (maps to SPEC `~/src/voxtype-mac-port/`)
**Machine:** arm64, macOS 26.6.2 (Build 25G83), Homebrew present, Xcode CLT present
**Date started:** 2026-09-06

## Locked runtime paths

```
STATE_PATH=/tmp/voxtype/state
AUDIO_SOCK=/tmp/voxtype/audio.sock
```

State values: `idle`, `recording`, `transcribing`, `streaming`. Missing file = not running / not hot.
macOS never sets `XDG_RUNTIME_DIR`; do not export it.

## Final hotkey

`FN` (Globe). Set **System Settings → Keyboard → Press 🌐 key to: Do Nothing**. Caps Lock remap LaunchAgent should be uninstalled for daily FN use.

## Phase checklist

- [x] Phase 0–4 (v2 Mac port) complete
- [x] v3 baseline: SPEC-v3.md + `.cache/baseline/` snapshot (2026-09-06)
- [x] v3 audio transport / UI lifecycle / art+physics (code + unit tests; live latency TBD)
- [x] v3 dictation candidate bench (CLI); keep `small.en`; cleanup is Swift `voxtype-clean`
- [x] Ship hygiene: `smart_auto_submit = false`, install order fixed, PopcornCore package split
- [ ] Live TCC DoD + SPEC §8 latency table (needs Caleb)

See also: [docs/metrics.md](docs/metrics.md), [SPEC-v3.md](SPEC-v3.md).

## Discoveries / failures

### Phase 0

- Linux reference files (`Popcorn.qml`, Linux config, `voxtype-clean`) absent on this Mac; recreating from SPEC §§4–6.
- Homebrew cask `peteonrails/voxtype/voxtype` installed **0.7.5**. Replaced with GitHub `voxtype-1.0.1-macos-universal` binary at `/opt/homebrew/bin/voxtype` (also overwrote Caskroom 0.7.5 file during earlier copy). Logged: **DMG/binary fallback to 1.0.1**.
- Official `voxtype-1.0.1-macos-universal` is Whisper-only (`parakeet` compiled=false). 2026-09-07: rebuilt 1.0.1 from source with `--features gpu-metal,parakeet,parakeet-coreml`. Official binary saved at `.cache/voxtype-1.0.1-macos-universal-official`. Active engine is NVIDIA Parakeet `parakeet-tdt-0.6b-v3`.
- Whisper `small.en` downloaded to `~/.local/share/voxtype/models/ggml-small.en.bin`.

### Phase 1

- Config installed; hotkey `FN`.
- Caps Lock → Right Option hidutil mapping was applied historically; uninstall for FN-only daily use.
- `voxtype setup app-bundle` created `/Applications/Voxtype.app`, Login Item, daemon running.
- Daemon log: Accessibility permission not granted (agent cannot click TCC). Hotkey listener still starts; typing requires Caleb to grant Accessibility + Input Monitoring + Microphone to **Voxtype**.

### Phase 2

- `bin/voxtype-clean` verified:
  - `VOXTYPE_CLEAN_APP=TextEdit` → `Hello world,` / `Hi,`
  - `VOXTYPE_CLEAN_APP=Terminal` → lowercase

### Phase 3

- **heap reconstructed; Linux QML absent** — 17 mound pieces seeded in `HeapSeed` (Tunables.swift).
- PopcornHUD release build OK; HUD now ships as `/Applications/VoicePop.app` (Login Item). Legacy LaunchAgent `com.caleb.popcornhud` retired.
- Audio path: nonblocking socket + generation fencing; production path does **not** inject synthetic heat (unavailable levels show detail text instead).
- Login Items currently include Voxtype (and unrelated Wispr Flow / Codex).

### Phase 4

- Scripts + README written.

### Improvement pass (2026-09-06)

- `smart_auto_submit = false` in repo + `~/.config/voxtype/`; Voxtype restarted.
- README builds `voxtype-clean` before `install-voxtype.sh`; install script warns instead of aborting if binary missing.
- Settled-kernel recycle, wall-clock enter/collapse, DisplayLink tick coalesce, EINPROGRESS connect wait, freeze after transcribing collapse.
- AppKit palette moved to HUD `Palette.swift`; duplicate corrupted SPEC-popcorn-v3 removed.

### Visual overhaul (2026-09-06)

- New `PopcornArt` library target (`Palette.swift`, `PopcornRenderer.swift`) — single Canvas renderer shared by `PopcornHUD` and `PopcornCapture`; capture PNGs now match the live HUD exactly.
- Kernels: hull remnant, per-lobe highlights (settled/heap only — airborne skip the pass for frame budget), hull-rooted creases, roughened outlines, `kernelRadius` 11 → 13.
- Bag: sagging front lip + dark interior, perspective stripes, left/right shading, scalloped rim, ground shadow. Far heap now draws *behind* the front wall so kernels read as inside the bucket.
- `setup-launch-agents.sh` packages and signs `VoicePop.app` (Apple Development; ad-hoc fallback). Do not install `bin/PopcornHUD`.

### Menu bar icon (2026-09-06)

- VoicePop.app menu bar, Dock, and Applications icon are the 🍿 emoji (not a template bag).
- Voxtype’s emoji tray (`🎙` AppLaunch parent) is suppressed on HUD launch and by `scripts/restart-voxtype.sh` (daemon child kept for TCC).
- Menu: status, toggle/cancel recording, edit config, restart Voxtype, quit HUD.

## TCC steps (agent cannot click)

1. Run `voxtype setup app-bundle` so grantee is **Voxtype** (`/Applications/Voxtype.app`).
2. System Settings → Privacy & Security → **Accessibility** → enable Voxtype.
3. **Input Monitoring** → enable Voxtype (required for key listener).
4. **Microphone** → enable Voxtype after first recording attempt.
5. PopcornHUD needs no permissions.
6. After `brew upgrade voxtype`, rerun `voxtype setup app-bundle` and re-grant 2–4.
7. Never run the daemon from Terminal for real use (TCC identity becomes Terminal).

## Section 9 — Definition of Done

| # | Test | Result |
|---|------|--------|
| 1 | `voxtype --version` ≥ 1.0.1 | PASS — `voxtype 1.0.1` |
| 2 | config diff empty; hotkey | PASS — `FN`; engine `parakeet`; `smart_auto_submit=false` |
| 3 | state idle→recording→transcribing→idle | PENDING — needs Input Monitoring/Accessibility (Caleb) |
| 4 | TextEdit typing | PENDING — TCC |
| 5 | Terminal typing (no capitalize) | PENDING — TCC; clean script unit-tested |
| 6 | Cursor/VS Code typing | PENDING — TCC |
| 7 | Popcorn visible ≤200 ms | PARTIAL — HUD enter uses wall-clock 140 ms; live PTT pending TCC |
| 8 | Popcorn exit ≤100 ms | PARTIAL — collapse 100 ms wall-clock then freeze capsule; live PTT pending TCC |
| 9 | No glass panel | PASS by design — bag + kernels only, clear panel |
| 10 | Cleanup `Hi,` | PASS |
| 11 | Restart persistence | PASS — Voxtype Login Item + VoicePop.app Login Item |
| 12 | Audio feed | PASS — socket path + nonblocking reader (connected only after SO_ERROR==0) |
