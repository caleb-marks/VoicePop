# VoicePop (macOS)

FN push-to-talk dictation via upstream Voxtype + VoicePop.app (popcorn HUD). Local only.

Built on [Voxtype](https://voxtype.io) by peteonrails for the speech engine; this repo adds the macOS menu-bar HUD, style rules, learned corrections, and install scripts. MIT licensed (see `LICENSE`).

Built with AI pair-programming (Claude Code, Codex). Architecture, product decisions, review, and macOS integration are mine.

<p align="center"><img src="docs/visuals/popcorn-loud-light.png" width="260" alt="VoicePop popcorn HUD while recording"></p>

## Install (download)

Apple Silicon, macOS 13+. Grab the latest `VoicePop-<version>-macos-arm64.zip` from [Releases](https://github.com/caleb-marks/VoicePop/releases), unzip, then:

```bash
cd ~/Downloads/VoicePop-*-macos-arm64 && ./install.sh
```

The installer sets up the Voxtype speech engine (bundled Parakeet-capable build), downloads the Parakeet model (about 2.4 GB, once), writes `~/.config/voxtype/config.toml` if you have none, and installs `/Applications/VoicePop.app`. Afterwards grant **Accessibility**, **Input Monitoring**, and **Microphone** to Voxtype in System Settings, and set **Keyboard → Press 🌐 key to: Do Nothing**.

The app is signed but not notarized. If macOS blocks it, right-click → Open once, or re-run `install.sh` (it clears quarantine). Building from source is under [One-time / after upgrade](#one-time--after-upgrade); `scripts/make-release.sh` produces the zip.

## Daily use

Hold **FN** (🌐) to record; release to type. Escape cancels.
Set **System Settings → Keyboard → Press 🌐 key to: Do Nothing** so Globe does not steal the key.
Popcorn bag reacts while recording; collapses to a **Transcribing…** capsule, then dismisses.

Open **VoicePop** from Applications — Dock icon plus a **VoicePop** menu-bar item. Opening again pops the menu. Quit from that menu stays quit until next login or you open the app again.

Menu bar → **Dictation model** picks **Parakeet** (NVIDIA `parakeet-tdt-0.6b-v3`, default) or Whisper (Tiny, Base, Small, Medium, Large turbo). The first time you pick a model that is not installed, VoicePop downloads it and restarts dictation. The Ready line shows the active model (`Ready · Parakeet`). **Fix “…”** is the last thing typed — click it if the model missed.

VoicePop warms the active model once after login (then unloads). The `[whisper] initial_prompt` hint list only applies to the Whisper engine, so it does nothing while Parakeet is active.
Names you say often (product names, people, jargon) are carried by `~/.config/voicepop/replacements.json` instead — seed or top it up with `scripts/seed-replacements.py`.

## Styles and learning

Menu bar → **Writing style**: **Automatic**, **Casual**, or **Formal**. The lower half is an override for the app you were just in (Messages → Casual, Mail → Formal). Terminals are never restyled.

**Fix last text…** opens what was just typed; edit it and **Save & Learn** (⌘↩). Those substitutions apply to future dictation. **More → Edit learned words…** opens the list for manual edits.

Files (plain JSON, local only): `~/.config/voicepop/style.json`, `history.jsonl` (every dictation, rotates at 1 MiB — delete it to clear), `corrections.jsonl`, `replacements.json`.

Formal can also polish with a local model (`qwen3.5:4b-mlx`). VoicePop starts `ollama serve` on demand (log: `/tmp/voicepop-ollama.log`) and leaves it running. Uncheck **Polish Formal with AI** to stay rules-only. If the model is slow or down, the rules output is typed unchanged within Voxtype's 5 s budget.

## One-time / after upgrade

Build companion binaries **before** install (config points at `bin/voxtype-clean`):

```bash
cd ~/VoicePop
./scripts/install-voxtype.sh
./scripts/uninstall-caps-remap.sh   # restore Caps Lock if remap was previously installed
./scripts/setup-launch-agents.sh    # packages VoicePop.app → /Applications, removes old LaunchAgent
```

After any HUD rebuild, rerun `./scripts/setup-launch-agents.sh` — it rebuilds, signs `VoicePop.app` with Apple Development (ad-hoc fallback), replaces `/Applications/VoicePop.app`, and launches it. Do not run a second HUD binary. If Dock/Finder keep the old icon: `killall Dock`.

Grant **Accessibility**, **Input Monitoring**, and **Microphone** to **Voxtype.app** (not Terminal, not VoicePop).

## Models

Default is NVIDIA Parakeet **`parakeet-tdt-0.6b-v3`** via a local 1.0.1 rebuild (`gpu-metal,parakeet,parakeet-coreml`). Official `macos-universal` is Whisper-only; that binary is saved at `.cache/voxtype-1.0.1-macos-universal-official`. Whisper models stay installed as a menu fallback.

## Rollback

```bash
cp .cache/voxtype-1.0.1-macos-universal-official /Applications/Voxtype.app/Contents/MacOS/voxtype-bin
cp .cache/voxtype-1.0.1-macos-universal-official /opt/homebrew/bin/voxtype
/Applications/Voxtype.app/Contents/MacOS/voxtype-bin config set engine whisper
./scripts/restart-voxtype.sh
```

## Timing instrumentation

Quit VoicePop first so only one HUD runs. `open -a` does **not** inherit env vars. Run the bundled binary:

```bash
POPCORNHUD_TIMING=1 /Applications/VoicePop.app/Contents/MacOS/VoicePop
```

## Specs

- [SPEC.md](SPEC.md) — original Mac port (v2)
- [SPEC-v3.md](SPEC-v3.md) — realistic popcorn + responsive dictation
- [NOTES.md](NOTES.md) — discoveries and DoD
