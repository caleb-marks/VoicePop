# Parakeet streaming: investigated 2026-09-09, blocked

**Question.** Can `[parakeet] streaming = true` be enabled - typing finalized segments while FN is
still held - without breaking push-to-talk?

**Answer: no, not without a 2.66 GB model swap *and* a patch to voxtype's Rust source.** Two
independent hard blockers. Both were verified in the shipped binary (`voxtype 1.0.1`,
`/opt/homebrew/bin/voxtype`), not just in `.cache/voxtype-src`.

## Blocker 1 - the installed model is not streaming-capable, and no file can fix that

`~/.local/share/voxtype/models/parakeet-tdt-0.6b-v3/` contains `encoder-model.onnx`,
`encoder-model.onnx.data`, `decoder_joint-model.onnx`, `vocab.txt`, `config.json`. There is no
`tokenizer.model`, and `parakeet-tdt-0.6b-v3` is registered `streaming_compatible: false`
(`.cache/voxtype-src/src/setup/model.rs:160-172`).

`ParakeetStreamingTranscriber::new` refuses *before* attempting a load
(`src/transcribe/parakeet_streaming.rs:68-83`):

> Parakeet streaming is enabled but model `parakeet-tdt-0.6b-v3` does not support cache-aware
> streaming.

Verify: `strings /opt/homebrew/bin/voxtype | grep 'does not support cache-aware streaming'`.

Dropping a `tokenizer.model` into the directory would not help. The comment at `:59-67` states that
istupakov's TDT-v3 also has a decoder graph the streaming inference loop cannot use, and would fail
at the first chunk with an ONNX Gather shape error instead.

The only streaming-capable model in the registry is `parakeet-unified-en-0.6b`
(`src/setup/model.rs:179-192`): **2.66 GB**, English-only, from
`bobNight/parakeet-unified-en-0.6b-onnx`. `voxtype info models --json` confirms
`downloadable: true, installed: false`. Install would be
`voxtype setup --download --model parakeet-unified-en-0.6b`.

## Blocker 2 - push-to-talk does not survive streaming, on any platform

`daemon.rs:2667-2679` rewrites `hotkey.mode` from `PushToTalk` to `Toggle` whenever
`Config::streaming_active()` is true (`src/config/root.rs:135-151`):

> Streaming transcription requires toggle activation, not push-to-talk. Auto-promoting [hotkey] mode
> from push_to_talk to toggle for this session.

Verify: `strings /opt/homebrew/bin/voxtype | grep 'Auto-promoting'`.

There is no `#[cfg(target_os)]` gate and no config opt-out. The stated reason is a libinput
held-key-tracking bug on Hyprland/Sway/River - irrelevant on macOS, but the code runs anyway. With
streaming on, holding FN and releasing would leave the daemon recording until FN is pressed again,
which is a different interaction model from the one VoicePop documents (`README.md:7`).

## What it would take

1. `voxtype setup --download --model parakeet-unified-en-0.6b` (2.66 GB), and
   `[parakeet] model = "parakeet-unified-en-0.6b"` - accepting an English-only model.
2. Patch `daemon.rs:2667` to skip the promotion under `#[cfg(target_os = "macos")]`, and rebuild
   voxtype locally with `--features gpu-metal,parakeet,parakeet-coreml`. Upstreaming that cfg gate is
   the clean version.
3. Re-verify FN hold/release end to end, and re-verify that streamed partials do not fight VoicePop's
   `[output.post_process]` cleanup.

Item 3 is the one that makes this more than a config change: VoicePop's whole text-cleanup and
learned-replacements pipeline runs on the *final* transcript (`voxtype-clean` is invoked once, from
`[output.post_process]`). Streaming would type raw model output at the cursor first, with no
mechanism to correct it afterwards. That interaction is unspecified today and needs its own design
pass.

**Decision: not in this pass.** Nothing in the polish/perf plan depends on it.
