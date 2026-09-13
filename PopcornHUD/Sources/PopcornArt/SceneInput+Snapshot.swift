import CoreGraphics
import PopcornCore

extension PopcornRenderer.SceneInput {
    /// The single mapping from simulation output to renderer input. The live HUD, the Settings
    /// appearance preview, and PopcornCapture all go through here, so adding simulated state
    /// (for example per-piece heap poses) only changes `SimSnapshot`, `SceneInput`, and this init.
    public init(
        snapshot: SimSnapshot,
        label: String,
        detail: String = "",
        presentation: HUDPresentation,
        reduceMotion: Bool,
        mascot: Mascot,
        showRecordingDot: Bool? = nil
    ) {
        var draws: [PopcornRenderer.KernelDraw] = []
        draws.reserveCapacity(snapshot.kernels.count)
        for k in snapshot.kernels {
            draws.append(PopcornRenderer.KernelDraw(
                front: k.front, settled: k.settled,
                x: CGFloat(k.x), y: CGFloat(k.y), scale: CGFloat(k.scale),
                rot: CGFloat(k.rot), shape: k.shape, butter: CGFloat(k.butter), alpha: k.alpha
            ))
        }
        self.init(
            heat: snapshot.heat,
            kick: snapshot.kick,
            bobPhase: snapshot.phase,
            label: label,
            detail: detail,
            presentation: presentation,
            reduceMotion: reduceMotion,
            bagVisible: snapshot.bagVisible,
            kernels: draws,
            showRecordingDot: showRecordingDot ?? (presentation == .recording),
            mood: snapshot.mood,
            mascot: mascot,
            heap: snapshot.heap
        )
    }

    /// A frame with nothing simulated: the empty host placeholder and the Transcribing capsule.
    public static func still(
        label: String,
        presentation: HUDPresentation,
        reduceMotion: Bool,
        mascot: Mascot,
        bagVisible: Double = 0
    ) -> PopcornRenderer.SceneInput {
        PopcornRenderer.SceneInput(
            heat: 0, kick: 0, bobPhase: 0, label: label, detail: "",
            presentation: presentation, reduceMotion: reduceMotion, bagVisible: bagVisible,
            kernels: [], showRecordingDot: presentation == .recording, mood: 0, mascot: mascot
        )
    }
}
