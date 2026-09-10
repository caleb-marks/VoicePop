# Nandor voice-polish verification - 2026-09-09T22:11:06Z

Production HUD remains Canvas-only. Beagle captures use the fixed 260×420 point scene at
actual size and 4× review scale; the beagle path uses only dog geometry and restrained motion.

## Checks

- `swift test --package-path PopcornHUD`: KernelArt hull/lobes + prior physics tests.
- `swift build --package-path PopcornHUD -c release`: passes.
- Dated 2026-09-06: then installed `bin/PopcornHUD` + LaunchAgent. Superseded by VoicePop.app.
- Seed 2026 sequence: quiet 0.035 (2 s), normal 0.12 (2 s), loud 0.28 (3 s),
  accents (2 s), silence (1 s). Light and dark backgrounds.
- Peak kernel count in capture: 27 (cap 120).
- Full sequence wall time (sim only path above): 266.7 ms.
- Offscreen Canvas renders (2× light+dark pair): median 0.16 ms,
  95th 0.19 ms. These are ImageRenderer measurements,
  **not** live display/compositor frame timings and **not** microphone-to-screen latency.
- Packet-to-render path is one display tick after `consumePeak` (held level between
  packets; onset only on fresh). Mic → Voxtype → socket → HUD is unmeasured here.

## Visual artifacts

- `beagle-quiet-light.png` / `beagle-quiet-dark.png` (actual size)
- `beagle-normal-light.png` / `beagle-normal-dark.png`
- `beagle-loud-light.png` / `beagle-loud-dark.png`
- `beagle-accents-light.png` / `beagle-accents-dark.png`
- `beagle-silence-light.png` / `beagle-silence-dark.png`
- `beagle-quiet-reducemotion-light.png` / `beagle-quiet-reducemotion-dark.png`
- `beagle-loud-reducemotion-light.png` / `beagle-loud-reducemotion-dark.png` (geometry must match quiet)
- `beagle-transcribing-light.png` / `beagle-transcribing-dark.png` (capsule only)
- `kernel-preview.png` (legacy popcorn route)
- `beagle-polish.mp4`: 60 fps deterministic input demo - **not** microphone footage.

## Still required (live)

Hold FN and speak quiet → normal → loud → accents → silence while the HUD is visible.
Do not count synthetic input or captures that miss the HUD as a mic pass.
Offscreen timings are not live compositor timings or microphone latency. System Reduce Motion,
app switching, host-field insertion, and repeated microphone cycles remain manual checks.