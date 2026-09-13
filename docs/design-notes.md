# Design notes

Decisions from the 1.2.0 polish that are not obvious from the code alone. Measurements and open live checks are in [metrics.md](metrics.md).

## HUD artwork and motion

- **Palette.** Tub stripes are `#C43037`. It was chosen over `#CB3538` (slightly pink at native size), `#C22E35` (heavy), and `#D23B3B` (toy-like) by rendered comparison on light and dark backgrounds. The recording dot is `#BF2F36` (5.3:1 on the capsule). Popcorn and beagle tokens are separate. The beagle stills must stay pixel-identical to their references unless the beagle is meant to change.
- **Kernels are pre-painted sprites.** Each shape × butter level × variant is painted once per display scale into a small bitmap (glaze, soft folds, no dark "Y" creases). A frame draws a shadow sprite, the rotated body sprite, and one scene-space light gradient, so airborne kernels and the pile share one light direction. This replaced about 15 vector operations per kernel and cut offscreen render time roughly threefold. The HUD prewarms sprites off the main thread for each screen scale.
- **The pile is a spring network** (`PopcornCore/HeapMotion.swift`), not a physics dependency. Each of the 42 decorative pieces has a spring for x, y, and rotation around its rest pose:
  - Stiffness and travel depend on exposure: crown pieces are loose, buried pieces nearly rigid.
  - Neighbors within 22 pt are coupled.
  - Speech drives smooth per-piece noise, which eases to an exact rest pose in pauses.
  - Launches, landings, and speech onsets add bounded impulses.
  - Landed kernels ride the displaced surface, and collisions use the same surface, so nothing hovers or sinks.
- **Determinism and bounds.** Everything runs on the fixed 120 Hz step with seeded streams; landings use their own stream so launches don't depend on landing timing. Displacement, rotation, velocity, population, and per-step work are clamped. A stall longer than 250 ms advances one step only. Reduce Motion pins the pile at rest and removes recoil, while keeping the recording dot and capsule.
- **One scene mapping.** The HUD, the Settings preview, and `PopcornCapture` all build renderer input with `SceneInput(snapshot:…)`, so previews and documentation captures show production motion.

## State, health, and recovery

- **Daemon state is event-driven** (`DaemonStateObserver`): vnode sources on the runtime directory, PID file, and state file, plus a process-exit source.
  - Identity changes (rename, delete, recreate) rebind the sources.
  - A 0-byte read keeps the last state, so truncate-then-write never flashes "missing".
  - It polls only while a watch can't be registered.
- **Daemon identity.** A PID counts as Voxtype if its executable is named `voxtype-bin` or `voxtype`, or lives inside a `Voxtype.app` bundle. If the path lookup fails, `kill(pid, 0)` is trusted. Restart refuses to launch `/Applications/Voxtype.app` while a daemon from another location is running, so two daemons never type the same text.
- **Health is evidence-based** (`DictationStatus`, `DictationSessionTracker`). The menu headline comes only from `DictationStatus.headline`, so it never says "Ready" while something blocks dictation. Failures VoicePop can actually distinguish:
  - a menu recording that never started;
  - no text after a real recording;
  - transcription stuck;
  - the daemon exiting mid-dictation;
  - repeated exact-zero microphone levels (heuristic).
- **Not observable from VoicePop:** FN press time, missing Input Monitoring (FN just does nothing), revoked Accessibility, and whether text reached the focused app. Wording stays neutral, and nothing claims insertion. Voxtype's "Text typed" log line only means keystrokes were posted.
- **Model identity.** Engine names can carry packaging suffixes (`…-int8-prepacked`). `ModelIdentity` ignores only known packaging suffixes. Prefix matching would wrongly treat `…-v3` as installed when only `…-v3-int8` is.
- **Process work** goes through `ProcessRunner`. It always drains or discards both pipes, supports timeouts, and stops delivering output lines once `run` returns. UI code never waits on a child process on the main thread.

## Setup checklist

- Engine and model state are re-probed each time the checklist opens. Setup downloads whatever model Voxtype is configured to load, and activates Parakeet only when nothing usable is configured.
- The permission, FN, and practice steps need functional evidence gathered while the checklist is visible:
  - a recording state not started from the menu;
  - a transcript;
  - dictated text arriving in the practice field within 5 s of that transcript, so typing by hand doesn't count.
- Evidence persists across interruptions. It is cleared only by a fresh Voxtype install or a `permissionsNeeded` status. Empty dictations are usually silence and don't clear it. Revoked Accessibility can't be detected, so the practice step is the way to re-check.
- Closing first-run setup before services start leaves the Dock icon as the way back; clicking it reopens the checklist.

## Persistence

- `style.json` and `replacements.json` round-trip unknown JSON fields, so older builds don't erase what newer builds or hand edits add.
- A corrupt file is never overwritten. It is quarantined to a timestamped `.bad` name, or the UI shows an explicit state with Reveal in Finder and Move Aside.
- Learned Words replays queued edits onto a fresh read of the file at save time. Words learned by the correction window meanwhile survive, and a failed edit is kept until a save succeeds.
- The correction window records what it already appended, so Retry never duplicates a `corrections.jsonl` entry. It tracks unsaved edits explicitly, and "Save & Learn" affects future dictation only.
- `VOICEPOP_CONFIG_DIR` redirects all VoicePop data for fixtures. Only directories VoicePop creates get `0700`.

## Tooling safety

- The UI snapshot harness (`VOICEPOP_UI_SNAPSHOT`) starts no services. It refuses to run unless `VOICEPOP_CONFIG_DIR` points somewhere other than `~/.config/voicepop`, and it exits non-zero if any of its recovery checks fail.
- The timing log (`~/Library/Logs/VoicePop/timing.log`, opt-in, `0600`) records event names and timestamps only: no transcript text, app names, or audio levels. The analyzer keeps only timestamps from Voxtype's own log.
