# Security Policy

## Scope

VoicePop is a local macOS menu-bar app. The dictation path makes no network calls: audio is captured, transcribed on-device by [Voxtype](https://voxtype.io) (NVIDIA Parakeet or OpenAI Whisper), post-processed locally, and typed into the focused app. Nothing is uploaded.

Two things do touch the network, both outside the dictation path:

- **Model downloads.** The first time you pick a dictation model, Voxtype fetches its weights.
- **Optional local LLM polish.** Formal style can route text through Ollama on `localhost`. That is a loopback call to a server you run.

## What VoicePop stores

Plain files in `~/.config/voicepop/`:

| File | Contents |
|---|---|
| `history.jsonl` | Recent transcripts, rotated at 1 MiB |
| `corrections.jsonl` | Corrections you saved |
| `replacements.json` | Learned substitutions |
| `style.json` | Per-app writing style |

Delete any of them to clear that data. VoicePop never transmits them.

## Permissions it asks for

Accessibility, Input Monitoring, and Microphone are granted to **Voxtype.app**, not to VoicePop. Voxtype needs Input Monitoring to see the FN key and Accessibility to type the result into the focused app.

## Supported versions

Only the latest release gets fixes.

## Reporting a vulnerability

Use GitHub's private reporting: open the repo's **Security** tab and click **Report a vulnerability** (direct link: https://github.com/caleb-marks/VoicePop/security/advisories/new). Please include the version, macOS version, and steps to reproduce. Do not open a public issue for anything that could be used against other users before there is a fix.

Expect an acknowledgement within a week. This is a solo side project, not a funded product — there is no bounty.
