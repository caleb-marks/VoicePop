# VoicePop metrics

> **Current default (since 2026-09-09):** NVIDIA Parakeet `parakeet-tdt-0.6b-v3-int8` on a local Voxtype 1.0.1 rebuild with `gpu-metal,parakeet,parakeet-coreml`. The engine may report the packaged variant `parakeet-tdt-0.6b-v3-int8-prepacked`; VoicePop treats it as the same model. Whisper `small.en` stays available as a fallback in **Settings → Dictation**.

This page separates three kinds of numbers. Keep them separate when you add results.

- **Measured (current):** reproduced on the stated build, machine, and fixture. Synthetic and offscreen measurements say so.
- **Target:** what the product should reach. A target is not a result.
- **Not measured:** needs the installed app, macOS permissions (TCC), and a person holding FN. The exact procedure is in [Live measurement procedure](#live-measurement-procedure).

All "current" measurements: Apple M4 MacBook Pro, 16 GB, macOS 26.6.2 (25G83), Swift 6.3.3, release (`-O`) builds, 2026-09-12 polish release candidate. None were taken against the running app, the live daemon, or real dictation.

## Targets and status

| Measure | Target | Status | Evidence |
|---|---|---|---|
| Recording request → visible feedback | p95 ≤ 100 ms | **Not measured live.** State detection is measured (synthetic). | State-file change → listener callback: p95 **1.29 ms** event-driven vs **97.0 ms** for the previous polling watcher. The HUD now publishes its first frame in the same main-queue turn as the state delivery. FN press time is inside Voxtype and not observable; the timing log uses Voxtype's "Recording started" line as a wall-clock proxy. |
| Fresh audio-level packet → visible reaction | p95 ≤ 33 ms | **Not measured live.** Instrumented. | `audio.react` timing event (packet arrival → publish that consumed it, ±1 ms). The HUD ticks at display rate and consumes the newest packet each tick, so the design bound is one display interval plus compositor latency. |
| Frame compute with up to 120 simulated kernels | p95 ≤ 4 ms | **Offscreen measure within target; live not measured.** | Sum of p95s (simulation + scene mapping + 2× offscreen render), three final runs: **1.4–2.5 ms** at loud speech, **2.3–3.9 ms** with 120 forced bodies. Other apps kept the load average near 2.5 during these runs, which explains the spread. Before the polish: 4.8–4.9 ms loud, 5.6–8.6 ms at 120 bodies. Offscreen `ImageRenderer` is not compositor frame time; live `hud.draw`/`hud.tick` need a real session. |
| Warm release → complete text, 3–10 s utterances | p95 ≤ 750 ms (report polishing separately) | **Not measured live.** | Fixture runs of `voxtype-clean` only: rules-only 34 ms; polish fallback when Ollama hangs 4.25 s; Ollama down 29 ms. Real polish latency is unmeasured (Ollama was not running). Recognition time inside Voxtype is not included. |
| Text inserted into the focused app | Confirmed insertion | **Not observable.** | VoicePop cannot see whether another app received text. Nothing claims insertion. Voxtype's `Text typed via CGEvent` line only means keystrokes were posted, and the analyzer labels it as unverified. |
| Hidden HUD | No HUD rendering or physics | **Met by design; verified by inspection and synthetic idle measure.** | Display link and fallback timer stop, audio socket stops, and the SwiftUI host is detached when hidden. The state observer has no timers when healthy: 10 s idle = **0** reads/wakeups (was 100) and 0.45 ms CPU (was 31.6 ms) in the isolated benchmark. Whole-app idle CPU is not measured. |
| Sustained recording | Bounded CPU, memory, population | **Bounded in simulation; live CPU/memory not measured.** | Unit tests hold population ≤ 120 bodies (≤ 40 resting) and the heap displacement, rotation, and velocity clamps over 60 s of energetic accented speech, and show no emission burst or heap jump after a 10 s stall. Sprite cache is populated once per display scale (estimated ≤ ~4 MB at 2×). |

## Current measurements

### Daemon state observation (synthetic)

`StateWatcher` is event-driven (`PopcornCore/DaemonStateObserver.swift`): vnode sources on the runtime directory, PID file, and state file, plus a process-exit source for the daemon. It polls only while a watch cannot be registered (50 ms backoff up to 2 s). The previous implementation polled every 100 ms while idle and every 8 ms while recording or transcribing.

Fixture: temporary runtime directory, a `/bin/sleep` child as the daemon PID, writes in Voxtype's truncate-then-write pattern, 60 randomized idle → recording → transcribing → idle cycles. Latency is from just before the write to the main-queue listener callback.

| Transition | Polling p50 / p95 / max (ms) | Event-driven p50 / p95 / max (ms) |
|---|---|---|
| → recording | 40.89 / 96.97 / 100.70 | 0.98 / 1.29 / 2.41 |
| → transcribing | 4.46 / 8.85 / 9.18 | 0.91 / 1.15 / 1.26 |
| → idle | 4.78 / 8.47 / 8.72 | 0.91 / 1.13 / 3.38 |
| Reads over 180 transitions | 9,392 | 352 |

No transitions were missed by either implementation.

| Edge case (event-driven) | Detected after |
|---|---|
| Truncate + write → recording | 1.05 ms |
| Atomic rename → transcribing | 1.66 ms |
| State file deleted → missing | 0.93 ms |
| State file recreated → idle | 1.23 ms |
| Daemon exit → missing | 1.23 ms |
| New daemon PID → idle | 3.00 ms |
| Runtime directory removed → missing | 0.64 ms |
| Runtime directory recreated (includes respawning the fake daemon) | 317 ms |

While `/tmp/voxtype` does not exist, the observer watches `/tmp` itself and coalesces those events to one check per 250 ms, so unrelated `/tmp` activity stays cheap. The cost is that a daemon starting from scratch is noticed up to ~250 ms later; recording transitions on a running daemon are unaffected.

100 start/stop cycles: at most 3 watcher descriptors open, 0 after stop, process descriptor count unchanged.

### Simulation and rendering (offscreen)

`PopcornCapture --bench`: seed 2026, 3 s warm-up, then 2,400 frames at 120 Hz (1,200 at 60 Hz) of 0.34-peak syllables. "Forced 120" tops the population up to 120 bodies every frame. Rendering uses `ImageRenderer` with pixel access forced, so it measures CPU raster work offscreen, not the live compositor.

| Measure (ms) | Before polish p50 / p95 | Current p50 / p95 |
|---|---|---|
| `advance` @120 Hz | 0.007 / 0.008 | 0.007 / 0.009 |
| `advance` @60 Hz (2 steps) | 0.012 / 0.019 | 0.013 / 0.020–0.021 |
| Collision @120 Hz | 0.004 / 0.005 | 0.003 / 0.004 |
| Whole-pile springs @120 Hz (42 pieces) | — | 0.001 / 0.001 |
| `advance`, forced 120 bodies | 0.018 / 0.021 | 0.017–0.018 / 0.020–0.021 |
| Collision, forced 120 bodies | 0.014 / 0.016 | 0.011 / 0.014 |
| Render loud scene @1× | 4.52 / 4.80 | 1.27–1.29 / 1.42–1.46 |
| Render loud scene @2× | 4.62 / 4.91 | 1.32–1.36 / 1.41–2.45 |
| Render forced-120 scene @2× | 5.5 / 5.6–8.6 | 1.9–2.7 / 2.3–3.9 |
| Kernel sprite cache, cold prewarm @1× (one time, background) | — | 97–98 ms |

Simulation was never the bottleneck (collision ≈ 0.014 ms at 120 bodies), so no broad-phase grid was added. The cost was per-kernel vector drawing (about 15 drawing operations and two transparency layers per kernel), which pre-painted kernel sprites replaced. The HUD prewarms sprites off the main thread at launch for each display scale.

### HUD publication (offscreen)

`hud-publish-bench`, energetic synthetic input (up to 68 kernels): assigning a new `rootView` costs p95 **0.2 µs**, and the Canvas closure costs p95 **0.48 ms**. Forcing a full CPU raster of the hosting view (`cacheDisplay`) costs p95 ~18 ms. That is an upper bound, not the GPU-backed live path. An `ObservableObject`-driven host was no cheaper, so publication was left as is.

### Optional polishing fallback (fixture)

Release `voxtype-clean`, temporary `VOICEPOP_CONFIG_DIR`, fake loopback server, synthetic sentence:

| Case | Wall time | Output | `clean.done llm=` |
|---|---|---|---|
| Polishing disabled | 34 ms | rules text | `off` |
| Server replies in 200 ms | 268 ms | polished text | `used` |
| Server hangs | 4,248 ms | rules text | `timeout` |
| Nothing listening | 29 ms | rules text | `down` |

The 4.2 s polishing deadline, 300 ms availability probe, and 3.5 s default timeout are unchanged. Tuning them needs live `llm=used` latency percentiles with the real model.

### Reproduce

```bash
swift build -c release --package-path PopcornHUD
PopcornHUD/.build/release/PopcornCapture --bench --json /tmp/capture-bench.json

PopcornHUD/Benchmarks/build.sh                      # -O tools in PopcornHUD/.build/bench
PopcornHUD/.build/bench/state-watcher-bench latency --impl both
PopcornHUD/.build/bench/state-watcher-bench idle --impl event
PopcornHUD/.build/bench/state-watcher-bench scenarios
PopcornHUD/.build/bench/state-watcher-bench lifecycle
PopcornHUD/.build/bench/hud-publish-bench
```

None of these launch VoicePop, talk to the running daemon, or read `~/.config`.

## Live measurement procedure

Needs a build of this code installed as `/Applications/VoicePop.app`, Voxtype permissions, and a person. Installing replaces the running app, so do it deliberately.

1. `defaults write com.caleb.voicepop VoicePopTiming -bool true`, quit and reopen VoicePop, then note `date -u +%Y-%m-%dT%H:%M:%SZ`.
2. In a scratch TextEdit document, dictate 20 times with FN: hold, speak a 3–10 s non-personal sentence, release, wait for the text.
3. Five times: menu **Start Recording** → speak → **Stop Recording**.
4. For polishing, repeat 10 dictations with Formal style while Ollama is already running.
5. `PopcornHUD/Benchmarks/build.sh`, then `PopcornHUD/.build/bench/timing-report ~/Library/Logs/VoicePop/timing.log --voxtype-log ~/Library/Logs/voxtype/stdout.log --since <time>`. The analyzer discards everything in Voxtype's log except the timestamps of its "Recording started/stopped" and "Text typed" lines.
6. Map report rows to targets:

   | Target | Report rows |
   |---|---|
   | Request → feedback | "menu request → recording state observed" + "state observed → first frame tick"; for FN, "Voxtype 'Recording started' → first frame tick" |
   | Packet → reaction | "fresh audio packet → HUD publish" (plus up to one refresh to glass) |
   | Frame compute | `hud.tick` / `hud.draw` |
   | Release → text | "3–10 s utterance: state left recording → text ready [llm=…]", reported per polishing state |

7. Turn timing off: `defaults delete com.caleb.voicepop VoicePopTiming`, relaunch, and optionally delete `~/Library/Logs/VoicePop/timing.log*`.

The timing log never contains transcript text, app names, or audio levels.

### Other live checks still open

| Check | Steps | Expected |
|---|---|---|
| Idle cost of the hidden HUD | VoicePop idle 60 s: `top -l 3 -s 5 -pid $(pgrep -x VoicePop) -stats pid,cpu,idlew,power` | ~0 % CPU and near-zero idle wakeups (the previous build polled at 10 Hz) |
| Engine restart | **Settings → General → Restart Dictation Engine**; click it again while restarting | Headline goes "Dictation isn’t running" → "Ready · Hold FN to dictate" without a HUD flash; only one restart happens |
| Display change / sleep during recording | Hold FN, change display arrangement or close and open the lid | HUD keeps animating; with timing on, `hud.clock reason=screens` or `wake` |
| Visual motion on real displays | Hold FN at quiet, normal, and loud levels on 1× and 2× displays, with and without Reduce Motion | Pile rocks and hops with speech and settles in pauses; Reduce Motion shows a still pile with the recording dot |
| VoiceOver | Turn on VoiceOver, start and stop a dictation, open Settings and the setup checklist | "Recording" and "Transcribing" are announced; controls have spoken labels |
| Onboarding on a clean account | New macOS user: open the release candidate from a DMG | Checklist installs the engine and model with progress; permission step completes only after the practice dictation types text |
| Login and multiple displays | Log out and back in; attach a second display with a different scale | VoicePop and the daemon start once; the HUD appears on the display with the pointer and renders crisply at each scale |
| Microphone device change | Switch input devices, or unplug a USB microphone, while recording | "Audio levels unavailable" appears after ~600 ms and clears when levels return |
| Revoked Accessibility | Turn off Voxtype in Accessibility, dictate, turn it back on | Not detectable by VoicePop; text simply isn't typed. The setup checklist can't notice this, so re-run the practice step after changing permissions |
| macOS 13 | Run the release candidate on macOS 13 | Settings, setup checklist, and HUD work (the deployment target is 13.0; development and all measurements were on macOS 26) |
| Microphone denied (optional, test account) | Deny Microphone for Voxtype, make two ≥ 1.5 s dictations | "Voxtype can’t hear the microphone" |

## Historical results

### Baseline (2026-09-06)

| Item | Value |
|------|-------|
| Hardware | Apple M4, 16 GB unified |
| Voxtype | 1.0.1 (`/opt/homebrew/bin/voxtype`) |
| Compiled engines | whisper only (others listed but not compiled) |
| Active model | Whisper `small.en` (~465 MB ggml): default at the time, superseded by Parakeet (see top) |
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

At that time every live target was recorded as blocked. The old note that the state watcher "polls every 20 ms" was inaccurate: it polled every 100 ms idle and every 8 ms while recording or transcribing, and it is now event-driven (see above).

### Candidate evaluation (40 TTS fixtures, CLI `voxtype transcribe`)

Each CLI invocation reloads the model, so latencies include load. This is useful for relative WER, not a substitute for warm daemon release-to-text. The default model was not changed during the 2026-09 polish.

| Candidate | WER mean | Latency median | Latency p95 | Status |
|-----------|----------|----------------|-------------|--------|
| Whisper small.en (baseline) | 0.137 | 0.32 s | 0.51 s | Default at the time |
| Whisper large-v3-turbo | 0.051 | 0.83 s | 1.13 s | Better accuracy, ~2.2× slower p95; not selected |
| Parakeet via 1.1.0-rc4 sideload | - | - | - | Blocked then: `Parakeet feature not enabled` (same as 1.0.1) |

Superseded 2026-09-07 by the Parakeet rebuild. Re-benching Parakeet on the same fixtures is still open.

## Unit tests

`swift test --package-path PopcornHUD` covers audio framing, text cleanup, styles, corrections and learned words (validation, unknown-field preservation, malformed files, retry without duplicate records), fixed-step physics and whole-pile motion (determinism, bounds under long loud input, silence settling, Reduce Motion, stalls), the event-driven state observer (rename, truncation, deletion, directory recreation, daemon exit and PID change, descriptor cleanup), dictation status and failure evidence, polishing fallback, the timing analyzer, and the setup checklist's evidence rules. Unit tests are not performance evidence.
