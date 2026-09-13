<h1 align="center">VoicePop</h1>

<p align="center">Push-to-talk dictation for macOS. Hold <b>FN</b>, speak, release - the text types itself into whatever app you were in.<br>Audio and speech recognition stay on your Mac.<br>Free and open source. No subscription or account.</p>

<p align="center">
  <a href="https://github.com/caleb-marks/VoicePop/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/caleb-marks/VoicePop/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B%20(Apple%20Silicon)-000?logo=apple&logoColor=white">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white">
  <img alt="Local speech recognition" src="https://img.shields.io/badge/speech%20recognition-local-2ea44f">
  <a href="https://github.com/caleb-marks/VoicePop/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/caleb-marks/VoicePop"></a>
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center"><img src="docs/visuals/demo-tub.gif" width="240" alt="VoicePop HUD reacting to speech, then collapsing to a Transcribing capsule"></p>

## Why

VoicePop brings hold-to-talk dictation, a responsive visual indicator, per-app writing styles, and learned corrections to macOS. It uses local speech recognition and offers optional text polishing through a loopback-only Ollama connection. The project focuses on a fast, predictable dictation workflow without a subscription.

A menu-bar app wraps a local speech engine ([Voxtype](https://voxtype.io), MIT, by peteonrails) and adds a HUD driven by live mic amplitude, per-app writing styles, and corrections that stick.

## What it does

- **Hold FN, talk, release.** Text lands in the focused app. Escape cancels.
- **Local speech.** NVIDIA Parakeet (`parakeet-tdt-0.6b-v3-int8`) by default, Whisper Tiny→Large-turbo as fallbacks. Audio and speech recognition remain on the Mac.
- **HUD that reacts to you.** Kernel physics driven by real mic amplitude at 60 fps, then a `Transcribing…` capsule, then gone. Honors Reduce Motion.
- **Writing style per app.** Automatic / Casual / Formal, with per-app overrides (Messages → Casual, Mail → Formal). Terminals are never restyled.
- **Corrections that stick.** Fix the last thing typed, hit **Save & Learn**; the substitution applies from then on. Plain JSON on disk.
- **Optional local polish.** Formal style can send transcript text to Ollama over a loopback-only connection (`qwen3.5:4b-mlx` by default). If it is slow or unavailable, rules output ships unchanged inside a 5 s budget. VoicePop blocks remote endpoints and non-loopback redirects; the Ollama service and model remain under your control.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/visuals/popcorn-quiet-dark.png"><img src="docs/visuals/popcorn-quiet-light.png" width="150" alt="HUD at a quiet speaking level - few kernels"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/visuals/popcorn-normal-dark.png"><img src="docs/visuals/popcorn-normal-light.png" width="150" alt="HUD at a normal speaking level"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/visuals/popcorn-loud-dark.png"><img src="docs/visuals/popcorn-loud-light.png" width="150" alt="HUD at a loud speaking level - kernels filling the frame"></picture>
</p>
<p align="center"><sub>Quiet, normal, loud - the same scene at three mic amplitudes. Dark-mode and Reduce Motion stills are in <a href="docs/visuals/">docs/visuals/</a>.</sub></p>

## Install

**[Download for Mac — Apple Silicon](https://github.com/caleb-marks/VoicePop/releases/latest/download/VoicePop.dmg)**


Apple Silicon, macOS 13+.

1. Download the latest asset from [Releases](https://github.com/caleb-marks/VoicePop/releases) - `.dmg` (drag to Applications). First launch must run from Applications; if you open the DMG copy, VoicePop will move itself there.
2. Open VoicePop. A setup checklist installs the speech engine, downloads the Parakeet model (~2.4 GB, once) with progress and retry, and guides the permissions Voxtype needs (**Accessibility**, **Input Monitoring**, **Microphone**) and a practice dictation. Reopen it any time from **Settings… → General → Check Setup…**.
3. Set **System Settings → Keyboard → Press 🌐 key to: Do Nothing** so Globe does not steal the key.

Signed with a Developer ID certificate and notarized by Apple, so Gatekeeper opens it without an override.

## How it works

```
FN keypress ──► Voxtype daemon ──► ASR (Parakeet / Whisper, Metal)
                    │                      │
              mic amplitude           raw transcript
              (unix socket)                │
                    ▼                      ▼
             PopcornHUD (SwiftUI)   voxtype-clean ──► style rules ──► learned
              60 fps kernel sim      (post-process)   (per-app)      replacements
                    │                                                    │
                    └────────────► "Transcribing…" ◄─────────────────────┘
                                          │
                              Voxtype types it ──► focused app
```

Swift packages: `PopcornCore` (audio framing, physics, text clean, style, corrections - the tested part), `PopcornArt` (renderers), `PopcornHUD` (menu bar, windows, watchers), `VoxtypeClean` (the post-processor Voxtype shells out to).

## Engineering notes

**Model choice was measured, not guessed.** The default today is Parakeet `tdt-0.6b-v3-int8`. It got there because of the bench below, not in spite of it.

The original run - 40 TTS fixtures, CLI transcribe, WER + latency - could only compare the two Whisper sizes the official macOS build shipped:

| Model | WER (mean) | Latency p95 | Verdict |
|---|---|---|---|
| Whisper `small.en` | 0.137 | 0.51 s | shipped as the original default |
| Whisper `large-v3-turbo` | 0.051 | 1.13 s | 2.2× slower p95 - rejected for a push-to-talk loop |
| Parakeet `tdt-0.6b-v3` | not measurable | not measurable | not compiled into the upstream macOS build |

Better accuracy was not worth doubling the tail latency on a key you hold down. And that third row - a model that could not be benched at all because the binary did not include it - is why the repo carries a local Voxtype rebuild with `gpu-metal,parakeet,parakeet-coreml` enabled. Parakeet became the default once it was runnable; the official Whisper-only binary is kept for one-command rollback. Re-benching Parakeet on the same 40 fixtures is still open - see [docs/metrics.md](docs/metrics.md).

Also here: fixed-step physics with a seeded RNG so HUD frames are reproducible in tests, opt-in timing instrumentation with a percentile report, and an honest [metrics doc](docs/metrics.md) that marks targets **blocked** where they still need a live-path probe rather than claiming a pass.

Built with AI pair-programming (Claude Code, Codex). Architecture, product decisions, review, and macOS integration are mine.

## Daily use

The menu bar shows what dictation is doing ("Ready · Hold FN to dictate") and offers a fix when something is wrong, such as restarting the engine. **Fix Last Dictation…** opens the last typed text: edit it, then **Save & Learn** (⌘↩) to teach future dictation, or **Copy Corrected Text**. VoicePop never rewrites text already in another app. **Writing Style** sets the global and per-app style. **Settings… (⌘,)** has General (open at login, FN key help, setup checklist, history), Appearance (mascot with a live preview), Dictation (models with download progress, styles, optional local polish), and Learned Words (search, add, edit, delete).

State is plain JSON in `~/.config/voicepop/`: `style.json`, `history.jsonl`, the retained rotation `history.1.jsonl`, `corrections.jsonl`, and `replacements.json`. VoicePop keeps the directory owner-only (`0700`) and those files owner-only (`0600`). Use **Settings… → General → Clear Transcript History…** to remove both history files while keeping saved corrections, learned replacements, and styles. Names you say often can be seeded via `scripts/seed-replacements.py`.

<details>
<summary><b>Build from source, rollback, instrumentation</b></summary>

Build companion binaries **before** install (config points at `bin/voxtype-clean`):

```bash
# from the repo root
./scripts/install-voxtype.sh
./scripts/uninstall-caps-remap.sh   # restore Caps Lock if remap was previously installed
./scripts/setup-launch-agents.sh    # packages VoicePop.app → /Applications
```

After any HUD rebuild, rerun `./scripts/setup-launch-agents.sh` - it rebuilds, signs, replaces `/Applications/VoicePop.app`, and relaunches. Never run a second HUD binary. Stale Dock icon: `killall Dock`.

Release builds use a pinned, locked Voxtype source revision and remap Rust and native compiler paths before packaging. Build without changing the installed engine:

```bash
./scripts/build-release-engine.sh /path/to/voxtype /tmp/voicepop-release-engine
VOXTYPE_BIN=/tmp/voicepop-release-engine/voxtype-bin \
VOXTYPE_PROVENANCE=/tmp/voicepop-release-engine/VOXTYPE-BUILD.txt \
  ./scripts/make-release.sh
./scripts/verify-release-artifacts.sh
```

Both downloads contain the VoicePop and upstream Voxtype licenses plus the exact source revision, feature set, and build settings used for the bundled engine.

Grant **Accessibility**, **Input Monitoring**, and **Microphone** to **Voxtype.app** (not Terminal, not VoicePop).

Roll back to the official Whisper-only engine:

```bash
cp .cache/voxtype-1.0.1-macos-universal-official /Applications/Voxtype.app/Contents/MacOS/voxtype-bin
cp .cache/voxtype-1.0.1-macos-universal-official /opt/homebrew/bin/voxtype
/Applications/Voxtype.app/Contents/MacOS/voxtype-bin config set engine whisper
./scripts/restart-voxtype.sh
```

Timing (private log, no transcript text; see [docs/metrics.md](docs/metrics.md#live-measurement-procedure)):

```bash
defaults write com.caleb.voicepop VoicePopTiming -bool true   # then quit and reopen VoicePop
PopcornHUD/Benchmarks/build.sh
PopcornHUD/.build/bench/timing-report ~/Library/Logs/VoicePop/timing.log
defaults delete com.caleb.voicepop VoicePopTiming
```

</details>

## Known limits

Apple Silicon only. The `[whisper] initial_prompt` hint list is dead weight while Parakeet is active - vocabulary goes in `replacements.json` instead. Live warm-path latency targets in [docs/metrics.md](docs/metrics.md) are still unmeasured.

## Docs

[docs/metrics.md](docs/metrics.md) — measurements, targets, and open live checks. [docs/design-notes.md](docs/design-notes.md) — why the HUD, recovery, and setup work the way they do. [SECURITY.md](SECURITY.md) — what runs locally, what touches the network, and what is stored on disk.

## Contributing

Issues and pull requests are welcome. Build and test with:

```bash
swift test --package-path PopcornHUD
```

`PopcornCore` is the tested target - put logic there. Full guidance in [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

Speech engine: [Voxtype](https://voxtype.io) by peteonrails (MIT). ASR models: NVIDIA Parakeet, OpenAI Whisper. VoicePop is MIT - see [LICENSE](LICENSE).

Release maintainers: see [Mac distribution](docs/mac-distribution.md) for signing, notarization, and the stable download asset.
