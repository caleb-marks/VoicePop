import Foundation
import CoreGraphics

public enum Paths {
    public static let state = "/tmp/voxtype/state"
    public static let audioSock = "/tmp/voxtype/audio.sock"
    public static let pid = "/tmp/voxtype/pid"
}

public enum Tunables {
    public static let cardW: CGFloat = 260
    public static let cardH: CGFloat = 420
    public static let bagBottomPad: CGFloat = 48 // status capsule below bag
    public static let bagH: CGFloat = 158
    public static let mouthHalf: CGFloat = 58
    public static let baseHalf: CGFloat = 44
    public static let baseCorner: CGFloat = 9
    public static let sidePinch: CGFloat = 3
    public static let toothCount = 10
    public static let toothH: CGFloat = 5
    public static let stripeCount = 9
    public static let capsuleW: CGFloat = 150
    public static let capsuleH: CGFloat = 28
    public static let statusFontSize: CGFloat = 13.5
    public static let marginPx: CGFloat = 40

    public static let simHz: Double = 120
    public static let simDt: Double = 1.0 / 120.0
    public static let maxCatchUpSteps = 8
    public static let maxKernels = 120
    /// Settled heap pieces kept for layering; oldest recycled when spawning under pressure.
    public static let maxSettledKernels = 40

    /// Design targets for sustained voice density (not AGC).
    public static let quietPopsPerSec: Double = 1.5
    public static let quietPopsPerSecMax: Double = 5.0
    public static let speechPopsPerSecMin: Double = 13
    public static let speechPopsPerSecMax: Double = 22
    public static let loudPopsPerSecMin: Double = 32
    /// Held at 40/s deliberately: at ~2.7 s mean kernel life that is already ~108 live bodies
    /// against `maxKernels` 120, so a higher ceiling would start hitting the capacity clamp.
    public static let ceilingPopsPerSec: Double = 40
    /// Burst *count* is unchanged; onset energy comes from the per-kernel accents below, which
    /// cost no extra bodies.
    public static let burstCountMin = 2
    public static let burstCountMax = 6
    public static let burstRefractory: Double = 0.080

    public static let minLaunch: Double = 200
    public static let launchRange: Double = 320
    /// Per-pop launch jitter (was ±6%): a wider spread of arcs reads as popping, not as a fountain.
    public static let launchJitterMin: Double = 0.88
    public static let launchJitterMax: Double = 1.12
    public static let gravity: Double = 1050
    public static let spreadPxPerSec: Double = 92
    /// Lateral spread scales with heat: `spreadHeatBase + heat * spreadHeatScale`.
    public static let spreadHeatBase: Double = 0.24
    public static let spreadHeatScale: Double = 1.05
    /// Tumble: `±spinRange * (spinHeatBase + heat * spinHeatScale)` rad/s at spawn.
    public static let spinRange: Double = 3.6
    public static let spinHeatBase: Double = 0.50
    public static let spinHeatScale: Double = 1.15
    /// Onset accents. A burst spawns the *same number* of kernels as before, but each one carries
    /// more energy, so a syllable reads as a hit instead of a slightly denser drizzle. Launch is
    /// still clamped by `maxLaunch` in `PopcornSim.spawnKernel`, so this cannot throw a kernel out
    /// of the panel.
    public static let burstLaunchAccent: Double = 1.15
    public static let burstSpreadAccent: Double = 1.50
    public static let burstSpinAccent: Double = 1.60
    public static let bounceRetainMin: Double = 0.22
    public static let bounceRetainMax: Double = 0.42
    public static let friction: Double = 0.82
    /// Bag recoil spring: ω ≈ 40 rad/s, ζ ≈ 0.7 → snaps back in ~120 ms with a small overshoot.
    public static let kickStiffness: Double = 1600
    public static let kickDamping: Double = 56
    public static let kickPerBurst: Double = 80
    /// Base recoil impulse scale (quiet ≈ subpixel, loud ≈ several px with spring).
    public static let kickPerPop: Double = 4.5
    public static let kickHeatScale: Double = 44
    public static let maxKickVelocity: Double = 220
    /// Squash-and-stretch of the bag per px of kick (bottom-anchored): wider, shorter.
    /// Raised so the recoil is visible without touching the spring itself: at the `maxKick` 8
    /// clamp this is sx 1.080 / sy 0.872, and at the spring's worst negative overshoot
    /// (kick ≈ -0.4) it is sx 0.996 / sy 1.006 — both strictly positive, no degenerate transform.
    public static let kickSquashX: Double = 0.010
    public static let kickSquashY: Double = 0.016

    public static let quietPeak: Double = 0.018
    public static let loudPeak: Double = 0.28
    public static let heatCurve: Double = 0.65
    /// Attack ~12 ms, release ~130 ms at 120 Hz (exponential rates).
    public static let attackRate: Double = 80
    public static let releaseRate: Double = 7.5
    /// Slow "mood" envelope that follows heat: ~150 ms up, ~870 ms down.
    /// Fast attack so it answers the first syllable; slow release so it eases off instead of
    /// dropping the moment you pause.
    public static let moodAttackRate: Double = 6.5
    public static let moodReleaseRate: Double = 1.15

    public static let enterMs: Double = 120
    public static let collapseMs: Double = 100
    public static let cleanupFade: Double = 0.120

    public static let kernelRadius: Double = 13
    /// Tighter cascade: 14 ms between accent pops reads as one hit, 20 ms reads as a roll.
    public static let burstSpacing: Double = 0.014
    /// Lower onset gate + faster baseline tracking: more syllables register as onsets, and the
    /// baseline re-arms fast enough that a sustained level still stops re-triggering.
    public static let onsetThreshold: Double = 0.10
    public static let onsetBaselineRate: Double = 20
    public static let maxKick: Double = 8

    // Quiet 1.5–5, normal 13–22, loud 32–40. Strictly increasing in both coordinates.
    private static let popCurve: [(Double, Double)] = [
        (0, 0),
        (0.18, quietPopsPerSec),
        (0.32, quietPopsPerSecMax),
        (0.50, speechPopsPerSecMin),
        (0.68, speechPopsPerSecMax),
        (0.85, loudPopsPerSecMin),
        (1.0, ceilingPopsPerSec),
    ]

    public static func popsPerSecond(heat: Double) -> Double {
        let h = min(1, max(0, heat))
        for i in 1..<popCurve.count where h <= popCurve[i].0 {
            let a = popCurve[i - 1], b = popCurve[i]
            return a.1 + (b.1 - a.1) * (h - a.0) / (b.0 - a.0)
        }
        return ceilingPopsPerSec
    }

    /// Shared curved mound, in scene coordinates before bag recoil.
    public static func heapSurface(x: Double) -> Double {
        let u = min(1, abs(x - Double(cardW) / 2) / Double(mouthHalf))
        // Match visible HeapSeed spill (~34–42 px above lip center).
        return Double(cardH - bagBottomPad - bagH) - 38 * (1 - u * u * 0.92)
    }

    public static let staleAudioMs: Double = 250
}

public struct HeapPiece: Equatable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat
    public var s: CGFloat
    public var far: Bool
    public var shape: Int
    public var rot: CGFloat
    public var butter: CGFloat

    public init(dx: CGFloat, dy: CGFloat, s: CGFloat, far: Bool, shape: Int, rot: CGFloat, butter: CGFloat) {
        self.dx = dx
        self.dy = dy
        self.s = s
        self.far = far
        self.shape = shape
        self.rot = rot
        self.butter = butter
    }
}

/// Asymmetric overlapping mound that fills the mouth and spills both shoulders.
public enum HeapSeed {
    private static let seeds: [HeapPiece] = [
        // Far row — fills rear lip
        .init(dx: -34, dy: -18, s: 0.88, far: true, shape: 0, rot: -0.55, butter: 0.14),
        .init(dx: -18, dy: -28, s: 1.05, far: true, shape: 3, rot: 0.72, butter: 0.20),
        .init(dx: -2, dy: -36, s: 1.14, far: true, shape: 1, rot: -0.22, butter: 0.18),
        .init(dx: 14, dy: -30, s: 1.02, far: true, shape: 6, rot: 0.95, butter: 0.22),
        .init(dx: 30, dy: -20, s: 0.90, far: true, shape: 4, rot: -0.80, butter: 0.15),
        .init(dx: 42, dy: -8, s: 0.82, far: true, shape: 9, rot: 0.35, butter: 0.12),
        .init(dx: -44, dy: -6, s: 0.80, far: true, shape: 2, rot: -1.05, butter: 0.12),
        // Near row — irregular spill over shoulders
        .init(dx: -28, dy: -8, s: 1.00, far: false, shape: 5, rot: 0.40, butter: 0.34),
        .init(dx: -12, dy: -16, s: 1.16, far: false, shape: 7, rot: -0.88, butter: 0.40),
        .init(dx: 4, dy: -20, s: 1.20, far: false, shape: 8, rot: 0.28, butter: 0.36),
        .init(dx: 18, dy: -14, s: 1.08, far: false, shape: 10, rot: -0.62, butter: 0.38),
        .init(dx: 32, dy: -6, s: 0.96, far: false, shape: 11, rot: 1.15, butter: 0.30),
        .init(dx: -38, dy: 2, s: 0.86, far: false, shape: 1, rot: -0.30, butter: 0.20),
        .init(dx: -6, dy: -2, s: 0.94, far: false, shape: 4, rot: 0.85, butter: 0.32),
        .init(dx: 10, dy: 0, s: 0.92, far: false, shape: 0, rot: -1.25, butter: 0.28),
        .init(dx: 26, dy: 2, s: 0.88, far: false, shape: 3, rot: 0.55, butter: 0.24),
        .init(dx: 40, dy: 1, s: 0.84, far: false, shape: 6, rot: -0.45, butter: 0.18),
        .init(dx: -20, dy: 4, s: 0.90, far: false, shape: 8, rot: 1.35, butter: 0.26),
        .init(dx: 22, dy: -24, s: 0.98, far: true, shape: 2, rot: 0.15, butter: 0.16),
        .init(dx: -8, dy: -24, s: 1.00, far: true, shape: 5, rot: -1.40, butter: 0.18),
    ]

    public static let pieces: [HeapPiece] = seeds
}
