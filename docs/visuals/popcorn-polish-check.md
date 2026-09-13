# Popcorn voice-polish verification - 2026-09-13T00:47:25Z

Production HUD remains Canvas-only. Popcorn captures use the
fixed 260×420 point scene and the production `SceneInput(snapshot:)` mapping; primary stills use 2× documentation scale with native 1× copies where applicable. Kernels are pre-rendered sprites under one scene-space light; the decorative pile is spring-simulated in `PopcornSim`.

## Checks

- Capture command: `PopcornCapture <output-directory> popcorn`.
- Seed 2026 sequence: quiet 0.035 (2 s), normal 0.12 (2 s), loud 0.28 (3 s),
  accents (2 s), silence (1 s). Light and dark backgrounds.
- Peak kernel count in capture: 63 (cap 120).
- Sequence generation wall time (simulation, still rendering, and PNG writes): 188.5 ms.
- Offscreen Canvas renders (2× light+dark pair): median 1.03 ms,
  95th 1.07 ms. These are ImageRenderer measurements,
  **not** live display/compositor frame timings and **not** microphone-to-screen latency.
  Layered release numbers come from `PopcornCapture --bench`.
- Packet-to-render path is one display tick after `consumePeak` (held level between
  packets; onset only on fresh). Mic → Voxtype → socket → HUD is unmeasured here.

## Visual artifacts

- `popcorn-quiet-light.png` / `popcorn-quiet-dark.png` (2× documentation stills)
- `popcorn-normal-light.png` / `popcorn-normal-dark.png`
- `popcorn-loud-light.png` / `popcorn-loud-dark.png`
- `popcorn-accents-light.png` / `popcorn-accents-dark.png`
- `popcorn-silence-light.png` / `popcorn-silence-dark.png`
- `popcorn-loud-reducemotion-light.png` / `popcorn-loud-reducemotion-dark.png` (simulated with Reduce Motion on: no pops, no pile motion)
- `popcorn-transcribing-light.png` / `popcorn-transcribing-dark.png` (capsule only)
- `popcorn-*-native1x.png` (native-scale copies) and `popcorn-loud-busy-native1x.png` (patterned backdrop)
- `kernel-preview.png` (kernel close-up, light and dark rows)
- `popcorn-polish.mp4`: 60 fps deterministic input demo, then the recording → transcribing collapse and one second of the capsule - **not** microphone footage.
- `demo-tub.gif`: 16 fps README hero derived from the same deterministic frames.

## Still required (live)

Hold FN and speak quiet → normal → loud → accents → silence while the HUD is visible.
Do not count synthetic input or captures that miss the HUD as a mic pass.
Offscreen timings are not live compositor timings or microphone latency. System Reduce Motion,
app switching, host-field insertion, and repeated microphone cycles remain manual checks.