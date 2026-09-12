# Premium popcorn HUD specification

Date: 2026-09-12. Requested workflow: research, specification, then implementation by Luna.

## Objective

Refine the existing popcorn HUD into a small, carefully illustrated cinema object with calm, readable status chrome. Keep its recognizable red-and-ivory popcorn identity and immediate response to speech. Success is visible in the shipped Canvas renderer at native size, rather than only in a large mockup.

## Research and design rationale

- [Apple: App Icon Design](https://developer.apple.com/videos/play/wwdc2017/822/) emphasizes an identifiable metaphor, simplicity, consistent visual weight, retaining identity through refinements, and testing at small sizes. Apply those principles to this illustrated HUD: retain the tub, simplify its outlines, and judge it at 260 × 420 points. This is an application of icon principles, not a claim that the HUD is an app icon.
- [Apple: Designing Fluid Interfaces](https://developer.apple.com/videos/play/wwdc2018/803/) relates responsive motion to interaction and physical behavior. Preserve the existing audio-driven physics and Reduce Motion behavior; improve the object around them.
- [Brokaw: Netflix Popcorn](https://www.brokaw.com/work/netflix-popcorn/) is a contemporary cinema/popcorn packaging reference. The design direction here is our interpretation: a limited palette, clear graphic identity, and intentional composition. Do not copy its logo or packaging artwork.

The local normal-light and normal-dark captures reveal a tall, narrow vessel; uniformly spaced bright stripes; a full rear rim painted over foreground kernels; strong red outlines; and a heavy rounded red label in a yellow capsule. These combine to make the UI feel more like clip art than finished product illustration. The kernels already have good organic silhouettes and deterministic motion worth preserving.

## Visual direction: refined cinema paperware

Use warm matte ivory paper, oxblood/cinema red ink, softly shaded curved walls, a thin rolled paper lip, and a restrained neutral status capsule. Keep the composition free of badges, brand words on the bucket, metallic decoration, new controls, and background cards.

### Geometry and layering

1. Preserve the 260 × 420 point scene and the mouth/heap/physics coordinates. Do not change simulation constants to achieve an art change.
2. Shorten the visible popcorn body by approximately 20–24 points at its bottom, with a slightly broader base (about 46–48 point half-width versus 44 today). Keep the mouth width at 116 points. This produces a more balanced tub without moving kernel launch/collision geometry. Define popcorn-specific drawing metrics in the renderer. Move its ground shadow and recording capsule up by the same amount; use the same capsule baseline for its collapsed state. Leave the beagle placement intact.
3. Make tapered walls smooth and subtly bowed, ending in a shallow rounded base. Use one coherent curvature for body and stripes.
4. Draw in this order: ground shadow; rear opening/rear lip; far heap; body and ink; near/settled heap; front lip only; airborne foreground kernels; status. The entire rim must not be drawn over the heap: its rear half belongs behind the popcorn.
5. Use a 3–4 point ivory rolled lip, soft inner occlusion, and a fine warm edge. Avoid the current double red ellipse. The opening should look filled with popcorn, with only small dark gaps between kernels.

### Color and material

These are initial tokens, adjustable slightly after rendered inspection:

| Role | Color / treatment |
| --- | --- |
| Paper | `#F5EDDC` warm ivory |
| Paper light | `#FFF9EC` |
| Paper shade | `#D9C8AA` |
| Cinema ink | `#973D3D` muted deep red |
| Ink shade | `#67272C` |
| Interior | `#594238` warm dark brown |
| Fine paper edge | `#BBA78A`, subdued opacity |
| Status surface | `#FAF7F1`, opaque enough to ensure consistent legibility |
| Status text | `#342F2C` |
| Recording dot | `#B44846` |

Add dedicated popcorn material tokens so unrelated beagle colors do not drift. Retain the kernels' creamy highlights; their existing shared rendering need not be redesigned.

Use approximately five red tapered panels separated by wider ivory gaps. Compress panels toward the sides to suggest a cylinder, with symmetric rhythm and an intentional center. Shade across the whole body with a broad upper-left highlight and soft right edge occlusion. Add a faint lower paper seam/base lip and a tight contact shadow. Avoid narrow glossy white streaks, heavy full outlines, per-frame noise, new blur stacks, or bitmap textures.

### Status capsule

For popcorn, use an opaque warm neutral surface, subtle 0.5–0.75 point border, a restrained shadow, and dark system text at roughly 12–13 points medium/semibold, default system design. Remove the bold rounded red typography and red capsule outline. Keep the existing 150 × 28 bounds unless label measurement warrants a modest change.

Center the dot-plus-label group optically using measured text width, with a 5–6 point recording dot and 7–8 point gap. Preserve status strings, the recording indicator, and transcribing behavior. Provide the premium style via a defaulted option or separate helper so the beagle's existing capsule remains unchanged. Detail text, when present, must remain legible and inside the scene.

### Motion, performance, and compatibility

Preserve launch rates, physics, deterministic seeds, accessibility label/value, click-through behavior, recording state, and supported macOS 13 deployment. Existing Reduce Motion must suppress airborne kernels, haze, heap bob, and recoil. Do not add decorative perpetual animation. Keep drawing in Canvas and reuse paths/gradients where useful; do not add dependencies or image assets for the live UI.

## Implementation scope

- Primary: `PopcornHUD/Sources/PopcornArt/PopcornRenderer.swift`.
- Tokens: `PopcornHUD/Sources/PopcornArt/Palette.swift`.
- Verification: `PopcornHUD/Sources/PopcornCapture/main.swift` and affected `docs/visuals` outputs.
- Preserve unrelated source behavior and user edits; no changes to dictation engines, setup settings, app icon, beagle art, or global physics tunables.

Extend the capture tool to emit popcorn Reduce Motion and transcribing stills on both backgrounds, plus native-scale stills if useful. Fix the generated verification report so it records measured results without hardcoded build/test/install claims, incorrect scale claims, or beagle-only artifact names in a popcorn report.

## Acceptance and handoff to Luna

1. Implement the specified production Canvas artwork; inspect native-size and enlarged light/dark stills and iterate if outlines, layers, or shadows look harsh.
2. Ensure the bucket silhouette is balanced, stripes read as ink on paper, the rear lip is behind the heap, and the front lip remains continuous without slicing the upper mound.
3. Check quiet, normal, loud, accents, silence, Reduce Motion, and transcribing. No clipped body/rim/text; transcribing contains only the status capsule. Preserve the beagle renderer's output.
4. Run `swift test --package-path PopcornHUD` and `swift build --package-path PopcornHUD -c release`.
5. Run the release `PopcornCapture` executable, regenerate affected stills and deterministic video, and report capture timing as offscreen timing only. Capture fixtures do not prove live microphone latency or compositor performance.
6. Leave a concise implementation/verification note with exact commands and limitations. Do not commit or publish. The parent agent will review final artwork and handle local installation after verification.
