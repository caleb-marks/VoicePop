# VoicePop metrics

> **Current default (since 2026-09-09):** NVIDIA Parakeet `parakeet-tdt-0.6b-v3-int8` on a local Voxtype 1.0.1 rebuild with `gpu-metal,parakeet,parakeet-coreml`. The baseline below predates that rebuild, so its "Blocked" Parakeet row and the `small.en` decision are historical. Whisper `small.en` stays installed as the menu fallback.

## Baseline (2026-09-06)

| Item | Value |
|------|-------|
| Hardware | Apple M4, 16 GB unified |
| Voxtype | 1.0.1 (`/opt/homebrew/bin/voxtype`) |
| Compiled engines | whisper only (others listed but not compiled) |
| Active model | Whisper `small.en` (~465 MB ggml) - default at the time; superseded by Parakeet (see top) |
| Acceleration | Metal (whisper.cpp) on Apple M4 |
| Hotkey | FN (Globe must be Do Nothing); Caps Lock remapping removed |
| HUD | PopcornHUD v3 (lobed kernels, fixed-step physics, corrected audio) |
| Baseline backup | `.cache/baseline/voxtype-1.0.1` + `config.toml` |
| `smart_auto_submit` | **false** (SPEC-v3) |

Rollback:

```bash
cp .cache/baseline/voxtype-1.0.1 /opt/homebrew/bin/voxtype
cp .cache/baseline/config.toml ~/.config/voxtype/config.toml
cp .cache/baseline/config.toml config/config.toml
./scripts/restart-voxtype.sh
```

## Acceptance targets (SPEC-v3 §8)

Live timing requires TCC + one HUD process. Quit VoicePop, then run the bundled binary (Launch Services does not inherit env):

```bash
POPCORNHUD_TIMING=1 /Applications/VoicePop.app/Contents/MacOS/VoicePop
# Hold FN, speak, release; inspect stderr for Timing.log lines.
```

Do **not** start a second HUD.

| Measure | Target | Result |
|---------|--------|--------|
| Socket frame → visible reaction p95 | ≤33 ms | **blocked** - needs live PTT + `POPCORNHUD_TIMING=1` after TCC |
| Mic → visible reaction p95 | ≤50 ms | **blocked** - no mic-side probe in HUD |
| Hotkey → recording indicator p95 | ≤100 ms | **blocked** - needs TCC + live PTT |
| HUD stop → audio stopped p95 | ≤50 ms | **blocked** - live timing TBD; generation fencing in unit path |
| Hidden UI render/physics | Zero when hidden | **pass by design** - display link stops when hidden (StateWatcher still polls state file every 20 ms; SPEC allows) |
| Frame compute @120 kernels p95 | ≤4 ms | **blocked** - needs live/instrumented session |
| Warm release→complete text 3–10s p95 | ≤750 ms | **blocked** - needs live dictation; CLI file bench ≠ daemon warm path |
| Engine vs baseline | ≥25% faster warm p95, no WER↑ | **fail for turbo on speed** (CLI relative; see below) - keep `small.en` |

## Candidate evaluation (40 TTS fixtures, CLI `voxtype transcribe`)

Note: each CLI invocation reloads the model; latencies include load. Useful for relative WER; not a substitute for warm daemon release-to-text. No further model swap until live warm-path metrics exist.

| Candidate | WER mean | Latency median | Latency p95 | Status |
|-----------|----------|----------------|-------------|--------|
| Whisper small.en (baseline) | 0.137 | 0.32 s | 0.51 s | **Selected default** |
| Whisper large-v3-turbo | 0.051 | 0.83 s | 1.13 s | Better accuracy, **~2.2× slower** p95 - not selected |
| Parakeet via 1.1.0-rc4 sideload | - | - | - | **Blocked**: `Parakeet feature not enabled` (same as 1.0.1) |

Decision at the time: keep `engine=whisper`, `model=small.en`. Superseded 2026-09-07 by the Parakeet rebuild. Turbo remains on disk for optional manual switch.

## Unit tests

`cd PopcornHUD && swift test` - audio framing, text clean, physics seed/bounds, settled-kernel recycle on long loud hold.
