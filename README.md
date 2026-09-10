<h1 align="center">VoicePop</h1>

<p align="center">Push-to-talk dictation for macOS. Hold <b>FN</b>, speak, release — the text types itself into whatever app you were in.<br>Speech never leaves the machine.<br>A free, open-source alternative to Wispr Flow and Superwhisper. No subscription, no account, no audio leaves the machine.</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B%20(Apple%20Silicon)-000?logo=apple&logoColor=white">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white">
  <img alt="Local only" src="https://img.shields.io/badge/cloud%20calls-0-2ea44f">
  <a href="https://github.com/caleb-marks/VoicePop/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/caleb-marks/VoicePop"></a>
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center"><img src="docs/visuals/demo.gif" width="240" alt="VoicePop HUD reacting to speech, then collapsing to a Transcribing capsule"></p>

## Why

Built-in macOS dictation is cloud-backed, punctuates badly, and gives no honest signal that it is listening. I dictate a lot — notes, messages, commit messages — and wanted three things Apple's version does not do together: **stay on the device**, **start typing in under a second**, and **look like it is listening** so I am not talking into a void.

VoicePop is that. A menu-bar app wraps a local speech engine ([Voxtype](https://voxtype.io), MIT, by peteonrails) and adds the parts that make dictation usable day to day: a HUD driven by live mic amplitude, per-app writing styles, and corrections that stick.

## What it does

- **Hold FN, talk, release.** Text lands in the focused app. Escape cancels.
- **Local speech.** NVIDIA Parakeet (`parakeet-tdt-0.6b-v3`) by default, Whisper Tiny→Large-turbo as fallbacks. No network calls in the dictation path.
- **HUD that reacts to you.** Kernel physics driven by real mic amplitude at 60 fps, then a `Transcribing…` capsule, then gone. Honors Reduce Motion.
- **Writing style per app.** Automatic / Casual / Formal, with per-app overrides (Messages → Casual, Mail → Formal). Terminals are never restyled.
- **Corrections that stick.** Fix the last thing typed, hit **Save & Learn**; the substitution applies from then on. Plain JSON on disk.
- **Optional on-device polish.** Formal style can run through a local LLM (`qwen3.5:4b-mlx` via Ollama). If it is slow or down, rules output ships unchanged inside a 5 s budget.

## Install

Apple Silicon, macOS 13+.

1. Download the latest asset from [Releases](https://github.com/caleb-marks/VoicePop/releases) — `.dmg` (drag to Applications) or `-macos-arm64.zip` (`./install.sh`).
2. Open VoicePop. First launch installs the speech engine, pulls the Parakeet model (~2.4 GB, once), and walks you through the two macOS switches it needs: **Accessibility** and **Input Monitoring** for Voxtype.
3. Set **System Settings → Keyboard → Press 🌐 key to: Do Nothing** so Globe does not steal the key.

Signed with an Apple Development certificate, not notarized. If macOS blocks it: **System Settings → Privacy & Security → Open Anyway**, once.

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

Swift packages: `PopcornCore` (audio framing, physics, text clean, style, corrections — the tested part), `PopcornArt` (renderers), `PopcornHUD` (menu bar, windows, watchers), `VoxtypeClean` (the post-processor Voxtype shells out to).

## Engineering notes

**Model choice was measured, not guessed.** 40 TTS fixtures, CLI transcribe, WER + latency:

| Model | WER (mean) | Latency p95 | Verdict |
|---|---|---|---|
| Whisper `small.en` | 0.137 | 0.51 s | shipped as baseline default |
| Whisper `large-v3-turbo` | 0.051 | 1.13 s | 2.2× slower p95 — rejected for a push-to-talk loop |
| Parakeet `tdt-0.6b-v3` | — | — | blocked: not compiled into upstream macOS build |

Better accuracy was not worth doubling the tail latency on a key you hold down. That "blocked" row is why the repo carries a local Voxtype rebuild with `gpu-metal,parakeet,parakeet-coreml` enabled — Parakeet is now the default, and the official Whisper-only binary is kept for one-command rollback.

Also here: fixed-step physics with a seeded RNG so HUD frames are reproducible in tests (57 tests: audio framing, text clean, physics bounds, kernel recycling), timing instrumentation behind `POPCORNHUD_TIMING=1`, and an honest [metrics doc](docs/metrics.md) that marks targets **blocked** where they still need a live-path probe rather than claiming a pass.

Built with AI pair-programming (Claude Code, Codex). Architecture, product decisions, review, and macOS integration are mine.

## Daily use

Menu bar → **Dictation model** switches engines (downloads on first pick, Ready line shows the active one). **Fix "…"** opens the last typed text; edit and **Save & Learn** (⌘↩). **More → Edit learned words…** for manual edits.

State is plain JSON in `~/.config/voicepop/`: `style.json`, `history.jsonl` (rotates at 1 MiB — delete to clear), `corrections.jsonl`, `replacements.json`. Names you say often are seeded via `scripts/seed-replacements.py`.

<details>
<summary><b>Build from source, rollback, instrumentation</b></summary>

Build companion binaries **before** install (config points at `bin/voxtype-clean`):

```bash
cd ~/VoicePop
./scripts/install-voxtype.sh
./scripts/uninstall-caps-remap.sh   # restore Caps Lock if remap was previously installed
./scripts/setup-launch-agents.sh    # packages VoicePop.app → /Applications
```

After any HUD rebuild, rerun `./scripts/setup-launch-agents.sh` — it rebuilds, signs, replaces `/Applications/VoicePop.app`, and relaunches. Never run a second HUD binary. Stale Dock icon: `killall Dock`. `scripts/make-release.sh` produces both release artifacts.

Grant **Accessibility**, **Input Monitoring**, and **Microphone** to **Voxtype.app** (not Terminal, not VoicePop).

Roll back to the official Whisper-only engine:

```bash
cp .cache/voxtype-1.0.1-macos-universal-official /Applications/Voxtype.app/Contents/MacOS/voxtype-bin
cp .cache/voxtype-1.0.1-macos-universal-official /opt/homebrew/bin/voxtype
/Applications/Voxtype.app/Contents/MacOS/voxtype-bin config set engine whisper
./scripts/restart-voxtype.sh
```

Timing (quit VoicePop first; `open -a` does not inherit env):

```bash
POPCORNHUD_TIMING=1 /Applications/VoicePop.app/Contents/MacOS/VoicePop
```

</details>

## Known limits

Apple Silicon only. Not notarized. The `[whisper] initial_prompt` hint list is dead weight while Parakeet is active — vocabulary goes in `replacements.json` instead. Live warm-path latency targets in [docs/metrics.md](docs/metrics.md) are still unmeasured.

## Docs

[SPEC.md](SPEC.md) — original Mac port · [SPEC-v3.md](SPEC-v3.md) — realistic popcorn + responsive dictation · [NOTES.md](NOTES.md) — discoveries and definition of done · [docs/metrics.md](docs/metrics.md) — benchmarks

## Credits

Speech engine: [Voxtype](https://voxtype.io) by peteonrails (MIT). ASR models: NVIDIA Parakeet, OpenAI Whisper. VoicePop is MIT — see [LICENSE](LICENSE).
