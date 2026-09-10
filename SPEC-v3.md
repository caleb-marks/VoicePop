# VoicePop v3: realistic popcorn and responsive dictation

Date: 2026-09-06  
Status: companion HUD + audio/physics largely implemented; live PTT latency and DoD still require TCC grants and measured validation (see `docs/metrics.md`, `NOTES.md`).

## 1. Outcome and scope

Make the popcorn look recognizable, move with believable collisions, react promptly to speech, and accompany fast, accurate local dictation.

This spec supersedes the original `SPEC.md` requirements to reproduce the old artwork and physics exactly, and to hide every indicator immediately after recording. Preserve the existing upstream Voxtype architecture, Caps Lock hold-to-talk, Escape cancellation, local processing, transparent floating panel, and nonactivating behavior. The panel must not intercept clicks or keyboard focus.

Implement through the companion HUD, supported Voxtype configuration/builds, and cleanup script. Do not rewrite the dictation engine. Do not silently change hold-to-talk to toggle, add a cloud service, or replace the system dictation installation before a candidate passes validation.

Writing this specification authorizes this document only; it does not install, restart, or modify the running application.

## 2. Observed baseline

Source inspection and read-only CLI checks established:

- Apple M4, 16 GB RAM; active Whisper model `small.en`. Installed Voxtype reports Whisper as the only compiled engine.
- Kernels are ellipses; the seeded heap mostly lies below the bag opening.
- Motion uses variable time increments, random rim bounces, no kernel-to-kernel collisions, and fading from the start of flight.
- The audio reading loop occupies the serial queue that also receives stop requests. This can starve stop processing. Several connection fields are accessed across queues without one synchronization policy.
- A read shorter than the 16-byte message size causes disconnect rather than buffering. A stream may legitimately deliver a message in several reads.
- Missing audio can generate synthetic activity, which looks like measured sound.
- The controller publishes a new SwiftUI root view at 60 Hz even when hidden. State is polled every 20 ms. Timing uses wall-clock dates.
- Transcribing causes the recording UI to exit. Status text is 11 points inside the bag.
- The cleanup script starts Python and additional processes for foreground-app detection. Its latency has not been measured.

These are implementation observations, not measured end-to-end latency or transcription accuracy results.

## 3. Popcorn appearance

Keep the red-and-cream striped bag. Refine its folds, rim, and shading without adding a large background panel.

1. Add 8–12 reusable kernel silhouettes, each with 3–5 uneven lobes, shallow creases, a small toasted center, warm white highlights, and restrained butter coloration. Avoid smooth oval outlines and uniformly yellow kernels.
2. Use cached vector paths in Canvas initially. Generate variation once per kernel, never new random geometry each frame. Keep highlights consistent with the scene lighting as kernels rotate.
3. Raise the visible heap above the opening. Layer the rear rim and inner shadow behind the heap; draw the front lip over returning kernels so they disappear inside the bag naturally.
4. Vary kernel size and rotation moderately. Preserve recognizable shapes at the actual displayed size, on both Retina and external displays.
5. Keep airborne kernels opaque for at least the first 75% of their visible flight. Retire kernels when hidden inside the bag or beyond the effect bounds; use brief fades only for visible cleanup.
6. Add a subtle outline/contact shadow so the bag remains readable against light, dark, and busy backgrounds.
7. Place the status in a compact capsule below the bag with 13–14-point text. Reserve layout space for it and for the highest permitted flight; prevent clipping at panel edges.

Visual acceptance: capture recording, quiet speech, loud speech, and transcribing at actual size and enlarged scale. Kernels must read as popcorn; the heap must visibly extend above the rim; return paths must respect front/back layering. Inspect on light and dark backgrounds.

## 4. Physics and speech response

Retain a lightweight two-dimensional simulation behind the existing renderer. Start with cached art and simple compound collision shapes—several small circles approximating each kernel. Do not introduce a full 3D renderer.

- Advance physics at fixed 1/120-second steps using a monotonic clock, which cannot jump when the system time changes. Interpolate drawing between simulation states. Cap catch-up work at eight steps per rendered frame and reset accumulated time after sleep or a long suspension.
- Collide airborne kernels with other active kernels, the rim, and the heap surface. Resolve overlap, apply friction, and reduce bounce energy on contact. Initial bounce retention: 0.2–0.35; tune visually. Replace random collision decisions with geometric contact checks.
- Give kernels angular velocity that changes on off-center impacts. Reduce rotation as they settle. Gravity must produce a clear rising arc, apex, and descent, without prolonged floating.
- Place launches in free space near the opening so particles do not begin deeply interpenetrating. Define a bounded landing region and recycle kernels below the visible heap. Stop simulating settled kernels until disturbed.
- Keep total simulated kernels at or below 120, including unsettled heap pieces. Reuse storage. Drop new spawns at capacity rather than accumulating a burst backlog.
- Start with 0–2 quiet pops per second, 12–25 during ordinary speech, and a ceiling of 40 during short emphasized phrases. Tune from real audio rather than random periodic bursts.
- Detect rapid increases in measured volume to trigger bursts of 2–5 kernels. Use a short refractory interval, initially 80 ms, to prevent one sound from triggering every frame. Apply a small, bounded recoil to the bag in response to the launch.
- Smooth the volume with a fast attack, initially 15–25 ms, and slower release, initially 100–160 ms. Calibrate the quiet threshold against background noise; do not let background hum continually trigger strong bursts.
- Reset every accumulator, collision state, burst timer, and velocity between sessions. Allow a fixed random seed for repeatable tests.

Equal time steps and contact subdivision follow established simulation practice; the exact values above are project starting points, not library mandates. [Box2D simulation guidance](https://box2d.org/documentation/md_simulation.html)

Physics acceptance: replay the same input at 30, 60, and 120 rendering frames per second. Contact outcomes must remain consistent within documented numeric tolerance. No persistent overlap, tunneling through the rim, runaway energy, offscreen clipping, or growing particle count during a 60-second recording. A frame stall must not produce an explosive catch-up burst.

## 5. Audio transport and lifecycle

Fix transport correctness before tuning the visuals.

1. Replace the endless blocking queue loop with nonblocking socket reads driven by a read event source. Keep connection ownership, buffers, reconnect timers, and lifecycle transitions on one serial queue; its handlers must always return promptly.
2. Make start/stop idempotent. Use a connection generation identifier so old callbacks cannot publish samples after a stop or a newer session. Coordinate cancellation and close to avoid closing a reused file descriptor.
3. Accumulate bytes and decode every complete 16-byte message, retaining any remainder. Verify the installed upstream protocol and byte order before implementing the parser. Handle interrupted reads and temporarily unavailable data without discarding valid bytes.
4. Reject nonfinite or invalid samples, clamp valid levels, and publish a timestamped latest-value snapshot through a lock or equivalent synchronized mechanism. Never read mutable connection fields directly from the UI thread.
5. Clear the last sample and buffered bytes on disconnect or session change. Treat audio as stale after 250 ms without a valid frame; distinguish unavailable levels from measured silence.
6. Remove production synthetic loudness. While recording with unavailable levels, show a steady recording indicator and small “Audio levels unavailable” detail. Do not claim microphone failure solely because the level socket is missing. Synthetic input belongs only in the test/preview harness.
7. Reconnect only while recording, with bounded retries; cancel pending retries immediately on stop. Stop must not wait for another audio message.

Acceptance: fragmented and combined messages decode correctly; invalid data never enters physics; repeated start/stop, silent sockets, disconnects, daemon restarts, and stale callbacks do not hang or revive a stopped session. Run 100 rapid cycles and check file-descriptor and memory stability.

## 6. UI lifecycle, performance, and accessibility

Use explicit states:

| State | Presentation |
| --- | --- |
| Idle | Hidden; no rendering or physics loop |
| Recording/streaming | Bag, measured speech response, readable recording status |
| Transcribing | Stop spawning; collapse bag within 100 ms into a small “Transcribing…” capsule |
| Completed | Brief completion indicator only when upstream provides a trustworthy completion signal |
| Cancelled | Stop activity and dismiss promptly; never show success |
| Unavailable/error | Brief accurate status from known daemon information; never invent an error or successful insertion |

The current state file does not prove successful insertion. Do not treat every return to idle as success. If upstream cannot distinguish completion, cancellation, and failure, dismiss neutrally and document the limitation.

- Use a display-synchronized callback where available. Stop animation work once hidden. Publish UI changes only when visible or when state changes; cache static drawing data.
- Keep current state polling unless measurements justify replacement. If adopting file events, handle atomic replacement, deletion, and recreation; retain bounded recovery polling.
- Correct entry scaling to use one coherent timing curve. Reposition on display/layout changes and keep the status capsule within the visible screen area.
- Respect Reduce Motion: static bag, no flight, bobbing, or recoil; retain readable state changes. Support increased contrast and expose one meaningful status element to VoiceOver, Apple's screen reader. Announce state changes, not particles or audio samples. [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## 7. Dictation speed and accuracy

### Preserve a known-working baseline

Record installed version, compiled engines, effective configuration, model, microphone, and acceleration evidence. Keep the existing executable/configuration recoverable. Verify candidate options against the exact installed version: development documentation may describe unavailable features.

### Candidates and selection

1. Baseline: current Whisper `small.en`.
2. Candidate: a verified compatible upstream macOS build with Parakeet TDT support. Confirm `info engines` and actual model initialization; listing a config section is not proof of support. Evaluate alongside the baseline before installation as the default. [Voxtype Parakeet documentation](https://voxtype.io/docs/PARAKEET)
3. Accuracy comparison: Whisper `large-v3-turbo`, if supported and within memory limits. Treat it as a candidate rather than assuming it is faster or better for this voice.

Keep the selected model resident if supported, and verify hardware acceleration from runtime evidence. Do not add guessed GPU configuration keys. Add a concise Whisper vocabulary hint for frequently used names and technical terms; score its effect on unseen phrases. Review microphone input quality and speech detection so quiet beginnings and endings are retained.

Evaluate processing audio during recording only if the chosen upstream version preserves Caps Lock hold-to-talk and Escape cancellation. Current development documentation describes toggle requirements for Whisper streaming. Do not enable it blindly. If compatible streaming is unavailable, retain batch transcription and report the limitation. Do not type unstable guesses into the active application. [Voxtype configuration reference](https://github.com/peteonrails/voxtype/blob/dev/docs/CONFIGURATION.md)

### Cleanup and insertion

Measure model inference, cleanup, and text insertion separately. Preserve cleanup behavior while reducing foreground-app lookup and process startup overhead if material. Prefer cached native foreground-app information where the supported integration permits it. Keep timeouts bounded and return original text on cleanup failure.

Retain supported macOS typing behavior and clipboard fallback. Verify long output, newlines, punctuation, and target focus in Notes/TextEdit, Terminal, Slack/Electron, and Cursor. Do not assume Linux paste settings work on macOS. Do not introduce automatic submission as a speed optimization.

## 8. Measurement and acceptance targets

Add opt-in timing instrumentation using monotonic timestamps. Ordinary logs must not contain dictated text or audio. Use consented existing fixtures or an explicit test recording session for voice evaluation.

Report median and p95, the time within which 95% of samples finish. Separate cold starts from warm runs, and record hardware, engine, model, clip duration, microphone, and concurrent load.

| Measure | Target |
| --- | --- |
| Valid socket frame received to visible reaction | p95 ≤33 ms |
| Microphone signal to visible reaction | p95 ≤50 ms; measure separately, not inferred from socket timing |
| Hotkey press to first visible recording indicator | p95 ≤100 ms |
| HUD stop request to audio reader stopped | p95 ≤50 ms, including a silent socket |
| Hidden UI work | Zero periodic rendering/physics updates |
| HUD frame computation under 120-kernel load | p95 ≤4 ms, excluding intentional display wait |
| Warm release to complete inserted text, 3–10-second clips | p95 ≤750 ms target; also report first-text delay |
| Engine improvement | ≥25% lower warm p95 release-to-complete-text time, with no increase in aggregate word error rate |

These are acceptance targets, not claims of achieved performance. If hardware or upstream constraints prevent a target, document actual results and the limiting stage; never label a missed target as passed.

Use at least 40 transcribed reference clips covering short commands, ordinary prose, names, numbers, punctuation, quiet speech, moderate noise, and longer 30–60-second passages. Replay identical audio for each engine, then verify live hotkey-to-insertion separately. Repeat latency runs at least three times. Keep a held-out subset for validation after tuning.

Score word error rate—substituted, missing, and extra words divided by reference words—and exact recognition of critical names/numbers. Report punctuation separately. A candidate must not regress the names/numbers subset or omit initial/final words. If no candidate improves both speed and accuracy, retain the baseline and report the measured tradeoff rather than selecting by speed alone.

## 9. Delivery order and evidence

1. Capture baseline and add repeatable transport/timing fixtures.
2. Fix audio lifecycle, buffering, stale data, and hidden rendering work.
3. Implement kernel artwork, layering, deterministic physics, and speech mapping.
4. Implement status transitions and accessibility.
5. Benchmark supported transcription candidates and optimize measured cleanup/insertion overhead.
6. Run integrated validation and document the selected configuration and rollback procedure.

Expected implementation areas: `AudioSocket.swift`, `PopcornSim.swift`, `PopcornView.swift`, `HUDController.swift`, `StateWatcher.swift`, `Tunables.swift`, configuration, and the cleanup script. Add focused tests for lifecycle, stream parsing, collision behavior, state transitions, and cleanup regressions. Do not substitute screenshot approval for correctness tests or synthetic timing for live end-to-end measurement.

Deliver updated source/configuration, reproducible tests, before/after visuals, a metrics table with pass/fail/blocked outcomes, and updated `NOTES.md`/README. Preserve recoverable copies before changing the installed binary or live configuration. Completion requires both visual inspection and measured functional results; untested claims remain explicitly unverified.
