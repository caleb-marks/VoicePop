# Premium popcorn UI review — 2026-09-12

Implemented by Luna from `docs/popcorn-premium-ui-spec.md`, then reviewed by the parent agent.

- Shortened the visible bucket by 22 points, broadened its base, and projected five ink panels around its curved surface.
- Separated front/rear paper lip layers, softened the contact shadow, and clipped the base seam into the body.
- Added a neutral status capsule with measured dot/text centering and a stable recording/transcribing baseline.
- Preserved all simulation tunables and the beagle's original capsule placement.

## Verification

- `swift test --package-path PopcornHUD`: 66 tests passed. Repeated against an isolated source snapshot containing this task's changes: 66 tests, zero failures.
- `swift build --package-path PopcornHUD -c release`: passed, including a clean isolated release build.
- `PopcornCapture docs/visuals popcorn`: regenerated light/dark stills, native 1× frames, Reduce Motion and transcribing frames, and the animated README hero.
- `python3 scripts/bench/png_compare.py <before-beagle> <after-beagle> --tolerance 0`: all 33 beagle/kernel PNGs matched exactly; no changed pixels.
- Reviewed native and enlarged output; verified that the base seam no longer floats beneath the bucket and the rear lip no longer crosses the popcorn heap.
- `git diff --check`: clean for this change.

The app was packaged and installed locally with the existing setup script from the isolated snapshot, because unrelated setup/signing edits appeared concurrently in the shared workspace. Those edits were preserved in the workspace and excluded from this installation. The installed app passed signature verification and was relaunched. The previous installed bundle was retained locally for rollback.

The captures use deterministic synthetic input. Live microphone-to-screen latency, compositor frame timing, and a full dictation cycle were not measured in this review.
