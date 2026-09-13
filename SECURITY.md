# Security Policy

## Scope

VoicePop is a local macOS menu-bar app. Audio is captured and transcribed on-device by [Voxtype](https://voxtype.io) (NVIDIA Parakeet or OpenAI Whisper), then typed into the focused app. VoicePop does not send audio to a remote service.

Two features use network APIs:

- **Model downloads.** The first time you pick a dictation model, Voxtype fetches its weights.
- **Optional local LLM polish.** Formal style can send transcript text, glossary terms, and recent correction examples to Ollama. VoicePop accepts only canonical loopback endpoints (`localhost`, `127.0.0.0/8`, or `::1`), bypasses configured proxies, and rejects redirects to non-loopback addresses. The Ollama service and model are separately installed and controlled by you; VoicePop cannot guarantee how a custom service processes data after receiving it locally.

## What VoicePop stores

Plain files in `~/.config/voicepop/`:

| File | Contents |
|---|---|
| `history.jsonl` | Recent transcripts, rotated at 1 MiB |
| `history.1.jsonl` | The previous transcript file retained after rotation |
| `corrections.jsonl` | Corrections you saved |
| `replacements.json` | Learned substitutions |
| `style.json` | Per-app writing style |

VoicePop requests owner-only permissions for this directory (`0700`) and these files (`0600`), including existing files it finds.

**Transcript history is optional.** **Settings… → General → Privacy → Save transcript history** (`privacy.saveHistory` in `style.json`, default on) controls whether dictations are appended to `history.jsonl`. When it is off, neither VoicePop nor the separate `voxtype-clean` process (which re-reads `style.json` on every dictation) writes new entries; existing entries are kept until you delete them. **Fix Last Dictation…** and **Copy Last Text** read only the newest saved entry, so with history off they offer nothing new. **Clear Transcript History…** deletes `history.jsonl` and `history.1.jsonl` after confirmation. Corrections and learned words are separate files, are not governed by the history setting, and are not touched by Clear Transcript History; delete them individually to clear their data.

## Clipboard

Voxtype types dictated text into the focused app using CGEvent keystrokes, then AppleScript keystrokes if that fails. Both need Accessibility permission for Voxtype. The config VoicePop writes sets `fallback_to_clipboard = true`, so when both typing methods fail Voxtype copies the text to the system clipboard with `pbcopy`. This replaces the previous clipboard contents and shows no notification (VoicePop turns Voxtype's notifications off). It happens most often when Accessibility permission has not been granted or has been revoked. **Copy Last Text** (menu and Settings) and **Copy Corrected Text** (Fix Last Dictation) also write to the clipboard, only when you choose them. VoicePop does not clear, restore, or expire clipboard contents. To disable the silent fallback, set `fallback_to_clipboard = false` under `[output]` in `~/.config/voxtype/config.toml`; a failed insertion is then dropped.

## Upgrades

When a copy of VoicePop launched from a DMG or Downloads installs itself, it copies the bundle to a hidden staging folder inside `/Applications`, verifies the copy (`codesign --verify --deep --strict`, bundle identifier, main executable) before touching the installed app, moves the installed copy to `~/Library/Application Support/VoicePop/Previous Versions/`, renames the verified copy into place, and launches it. If the swap or launch fails, the previous version is put back and the alert says where the failed copy is. Only the newest previous version is kept.

## Logs

VoicePop writes no transcript text to logs.

| File | When |
|---|---|
| `~/Library/Logs/VoicePop/timing.log` | Only when timing is turned on (`defaults write com.caleb.voicepop VoicePopTiming -bool true` or `POPCORNHUD_TIMING=1`). Event names and timestamps only; no transcript text, app names, or audio levels. Directory `0700`, file `0600`. |
| `~/Library/Logs/VoicePop/ollama.log` | Output of an Ollama server that VoicePop started for optional polish (`0600`). Previously `/tmp/voicepop-ollama.log`. |

## Permissions it asks for

Accessibility, Input Monitoring, and Microphone are granted to **Voxtype.app**, not to VoicePop. Voxtype needs Input Monitoring to see the FN key and Accessibility to type the result into the focused app.

## Supported versions

Only the latest release gets fixes.

## Reporting a vulnerability

Use GitHub's private reporting: open the repo's **Security** tab and click **Report a vulnerability** (direct link: https://github.com/caleb-marks/VoicePop/security/advisories/new). Please include the version, macOS version, and steps to reproduce. Do not open a public issue for anything that could be used against other users before there is a fix.

Expect an acknowledgement within a week. This is a solo side project, not a funded product — there is no bounty.
