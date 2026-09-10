import Foundation

/// Deterministic RNG (xorshift64). Seed via POPCORNHUD_SEED or time.
public struct SeededRNG: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public static func fromEnvironment() -> SeededRNG {
        if let s = ProcessInfo.processInfo.environment["POPCORNHUD_SEED"], let v = UInt64(s) {
            return SeededRNG(seed: v)
        }
        return SeededRNG(seed: UInt64(Timing.nowMs()) ^ 0xA5A5_5A5A_DEAD_BEEF)
    }

    public mutating func nextUInt64() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    public mutating func nextDouble() -> Double {
        Double(nextUInt64() >> 11) / Double(1 << 53)
    }

    public mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextDouble()
    }

    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound + 1
        return range.lowerBound + Int(nextUInt64() % UInt64(span))
    }

    public mutating func nextBool() -> Bool { nextDouble() < 0.5 }
}
