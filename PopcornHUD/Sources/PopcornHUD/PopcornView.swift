import AppKit
import SwiftUI
import PopcornArt
import PopcornCore

/// One published HUD frame: window-level opacity/scale around the renderer's scene.
/// Build `scene` with `PopcornRenderer.SceneInput(snapshot:…)` so HUD and previews share one mapping.
struct PopcornFrame: Equatable {
    var opacity: Double
    var scale: Double
    var scene: PopcornRenderer.SceneInput
}

struct PopcornView: View {
    var frame: PopcornFrame

    var body: some View {
        Canvas { ctx, _ in
            PopcornRenderer.drawScene(ctx: &ctx, scene: frame.scene)
        }
        .frame(width: Tunables.cardW, height: Tunables.cardH)
        .scaleEffect(frame.scale, anchor: .bottom)
        .opacity(frame.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(frame.scene.label)
        .accessibilityValue(frame.scene.detail.isEmpty ? Text(frame.scene.label) : Text(frame.scene.detail))
        .allowsHitTesting(false)
    }
}
