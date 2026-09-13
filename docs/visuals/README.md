# Visual captures

All captures come from `PopcornCapture` with deterministic synthetic input (seed 2026), rendered offscreen through the same `SceneInput(snapshot:)` mapping the HUD uses. None of it is microphone footage.

- `demo-tub.gif` — README hero: the HUD reacting to quiet → normal → loud → accented speech and a pause, then the tub fading into the Transcribing capsule.
- `popcorn-*.png` / `beagle-*.png` — stills of the two mascots (quiet / normal / loud / silence / accents; both also have Reduce Motion and transcribing).
- `popcorn-*-native1x.png` — native-scale popcorn stills for small-size review, plus `popcorn-loud-busy-native1x.png` on a cluttered backdrop.
- `kernel-preview.png` — kernel close-up: six shapes on light, six on black, with increasing and decreasing butter.
- `popcorn-polish-check.md` / `beagle-polish-check.md` — generated notes for those stills.

Regenerate from the repository root:

```bash
swift build -c release --package-path PopcornHUD --product PopcornCapture
PopcornHUD/.build/release/PopcornCapture docs/visuals popcorn
PopcornHUD/.build/release/PopcornCapture docs/visuals beagle   # only if the beagle changed
```

Review and measurement modes write outside `docs/visuals/`:

- `PopcornCapture --review <dir>` — every documented frame on light, dark, gray, mid-gray, and busy backdrops at 1×, 2×, and 4×.
- `PopcornCapture --motion <dir>` — pile motion evidence: contact sheets (full, pile-only, heap-only), a frame-by-frame collapse sheet, Reduce Motion, a per-piece `heap-trace.csv`, and MP4/GIF clips.
- `PopcornCapture --bench [--json out.json]` — release-build costs: simulation (with collision and heap phases), scene mapping, and offscreen rendering at 1× and 2×, including a forced 120-kernel population. Offscreen `ImageRenderer` timings are not compositor frame times.
