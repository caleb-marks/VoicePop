import Foundation

public enum SyntheticIntensity: String, CaseIterable, Sendable {
    case quiet, normal, energetic
}

/// Deterministic microphone-level stand-in for previews, captures, and tests. Never touches
/// audio hardware. Emits 100 Hz "packets" (like the Voxtype socket) with syllable-like bursts
/// and short pauses so the production simulation sees realistic onsets.
public struct SyntheticSpeech: Sendable {
    public var intensity: SyntheticIntensity
    private var rng: SeededRNG
    private var lastPacketMs: UInt64?
    private var syllableEndMs: UInt64 = 0
    private var syllablePeak: Float = 0
    private var current: Float = 0

    public init(intensity: SyntheticIntensity, seed: UInt64 = 7) {
        self.intensity = intensity
        rng = SeededRNG(seed: seed)
    }

    private var peakRange: ClosedRange<Double> {
        switch intensity {
        case .quiet: return 0.025...0.05
        case .normal: return 0.08...0.16
        case .energetic: return 0.20...0.34
        }
    }

    /// Level for display time `monoMs`. `fresh` is true when a new 10 ms packet boundary passed.
    public mutating func sample(atMonoMs monoMs: UInt64) -> (peak: Float, fresh: Bool) {
        if let last = lastPacketMs, monoMs &- last < 10, monoMs >= last {
            return (current, false)
        }
        lastPacketMs = monoMs
        if monoMs >= syllableEndMs {
            // 30% chance of a short pause between syllables.
            if rng.next(in: 0...1) < 0.3 {
                syllablePeak = 0.004
                syllableEndMs = monoMs &+ UInt64(rng.next(in: 90...260))
            } else {
                syllablePeak = Float(rng.next(in: peakRange))
                syllableEndMs = monoMs &+ UInt64(rng.next(in: 110...240))
            }
        }
        let jitter = Float(rng.next(in: 0.85...1.0))
        current = syllablePeak * jitter
        return (current, true)
    }
}
