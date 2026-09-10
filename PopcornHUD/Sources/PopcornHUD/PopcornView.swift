import AppKit
import SwiftUI
import PopcornArt
import PopcornCore

struct PopcornFrame: Equatable {
    var opacity: Double
    var scale: Double
    var bagVisible: Double
    var heat: Double
    var mood: Double
    var kick: Double
    var bobPhase: Double
    var label: String
    var detail: String
    var presentation: HUDPresentation
    var reduceMotion: Bool
    var kernels: [PopcornRenderer.KernelDraw]
    var mascot: Mascot = .popcorn
}

struct PopcornView: View {
    var frame: PopcornFrame

    var body: some View {
        Canvas { ctx, size in
            let scene = PopcornRenderer.SceneInput(
                heat: frame.heat,
                kick: frame.kick,
                bobPhase: frame.bobPhase,
                label: frame.label,
                detail: frame.detail,
                presentation: frame.presentation,
                reduceMotion: frame.reduceMotion,
                bagVisible: frame.bagVisible,
                kernels: frame.kernels,
                showRecordingDot: frame.presentation == .recording,
                mood: frame.mood,
                mascot: frame.mascot
            )
            PopcornRenderer.drawScene(ctx: &ctx, scene: scene)
        }
        .frame(width: Tunables.cardW, height: Tunables.cardH)
        .scaleEffect(frame.scale, anchor: .bottom)
        .opacity(frame.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(frame.label)
        .accessibilityValue(frame.detail.isEmpty ? Text(frame.label) : Text(frame.detail))
        .allowsHitTesting(false)
    }
}
