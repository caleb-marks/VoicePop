import Foundation

/// 16-byte native-endian Voxtype audio.sock frame.
public struct AudioFrame: Equatable, Sendable {
    public var seq: UInt32
    public var min: Float
    public var max: Float
    public var peakDbfs: Float

    public static let byteCount = 16

    public init(seq: UInt32, min: Float, max: Float, peakDbfs: Float) {
        self.seq = seq
        self.min = min
        self.max = max
        self.peakDbfs = peakDbfs
    }

    public var peak: Float {
        Swift.min(1, Swift.max(abs(min), abs(max)))
    }

    public var isValid: Bool {
        min.isFinite && max.isFinite && peakDbfs.isFinite && peak.isFinite
    }

    public static func decode(_ bytes: ArraySlice<UInt8>) -> AudioFrame? {
        guard bytes.count >= byteCount else { return nil }
        return bytes.withUnsafeBytes { raw -> AudioFrame? in
            guard raw.count >= byteCount else { return nil }
            let seq = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let mn = raw.loadUnaligned(fromByteOffset: 4, as: Float.self)
            let mx = raw.loadUnaligned(fromByteOffset: 8, as: Float.self)
            let db = raw.loadUnaligned(fromByteOffset: 12, as: Float.self)
            let f = AudioFrame(seq: seq, min: mn, max: mx, peakDbfs: db)
            return f.isValid ? f : nil
        }
    }

    public func encode() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: Self.byteCount)
        buf.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: seq, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: min, toByteOffset: 4, as: Float.self)
            raw.storeBytes(of: max, toByteOffset: 8, as: Float.self)
            raw.storeBytes(of: peakDbfs, toByteOffset: 12, as: Float.self)
        }
        return buf
    }
}

/// Accumulates socket bytes and emits complete frames.
public final class AudioFrameBuffer {
    private var pending: [UInt8] = []
    private var offset = 0

    public init() {}

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        offset = 0
    }

    public func append(_ bytes: [UInt8]) -> [AudioFrame] {
        bytes.withUnsafeBufferPointer { append($0) }
    }

    public func append(_ bytes: UnsafeBufferPointer<UInt8>) -> [AudioFrame] {
        if offset > 0, offset >= pending.count {
            pending.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 256 {
            pending.removeFirst(offset)
            offset = 0
        }
        pending.append(contentsOf: bytes)
        var out: [AudioFrame] = []
        while pending.count - offset >= AudioFrame.byteCount {
            let end = offset + AudioFrame.byteCount
            let slice = pending[offset..<end]
            if let frame = AudioFrame.decode(slice) {
                out.append(frame)
            }
            offset += AudioFrame.byteCount
        }
        return out
    }
}

public struct AudioSnapshot: Equatable, Sendable {
    public var peak: Float
    public var connected: Bool
    public var levelsAvailable: Bool
    public var stale: Bool
    public var monotonicMs: UInt64

    public init(peak: Float, connected: Bool, levelsAvailable: Bool, stale: Bool, monotonicMs: UInt64) {
        self.peak = peak
        self.connected = connected
        self.levelsAvailable = levelsAvailable
        self.stale = stale
        self.monotonicMs = monotonicMs
    }

    public static let empty = AudioSnapshot(
        peak: 0, connected: false, levelsAvailable: false, stale: true, monotonicMs: 0
    )
}

/// Distinguishes a new audio packet from a held level, silence, or stale/disconnected audio.
public enum AudioLevelFreshness: Equatable, Sendable {
    /// One or more frames arrived since the last consume.
    case fresh
    /// Connected with levels available, but no new frame — reuse last fresh peak.
    case held
    /// Stale or disconnected — stop driving pops.
    case unavailable
}

public struct AudioLevelSample: Equatable, Sendable {
    public var peak: Float
    public var freshness: AudioLevelFreshness
    public var snapshot: AudioSnapshot

    public init(peak: Float, freshness: AudioLevelFreshness, snapshot: AudioSnapshot) {
        self.peak = peak
        self.freshness = freshness
        self.snapshot = snapshot
    }
}

/// Pure hold/consume logic so display refresh and packet arrival stay independent.
public struct AudioLevelHold: Equatable, Sendable {
    public var lastFreshPeak: Float = 0
    public var peakSinceConsume: Float = 0
    public var hadFramesSinceConsume = false
    public var lastFrameMono: UInt64 = 0
    public var snapshot = AudioSnapshot.empty

    public init() {}

    public mutating func publish(peak: Float, monoMs: UInt64) {
        let p = peak.isFinite ? max(0, min(1, peak)) : 0
        peakSinceConsume = max(peakSinceConsume, p)
        lastFreshPeak = p
        hadFramesSinceConsume = true
        lastFrameMono = monoMs
        snapshot = AudioSnapshot(
            peak: p,
            connected: true,
            levelsAvailable: true,
            stale: false,
            monotonicMs: monoMs
        )
    }

    public mutating func markDisconnected() {
        snapshot.connected = false
        snapshot.levelsAvailable = false
        snapshot.stale = true
        lastFreshPeak = 0
        peakSinceConsume = 0
        hadFramesSinceConsume = false
    }

    public mutating func reset() {
        snapshot = .empty
        lastFreshPeak = 0
        peakSinceConsume = 0
        hadFramesSinceConsume = false
        lastFrameMono = 0
    }

    /// Apply stale gate, then return the sample for this display tick.
    public mutating func consume(nowMs: UInt64, staleMs: UInt64) -> AudioLevelSample {
        if snapshot.levelsAvailable, lastFrameMono > 0, nowMs &- lastFrameMono > staleMs {
            snapshot.stale = true
            snapshot.levelsAvailable = false
        }

        if !snapshot.connected || !snapshot.levelsAvailable || snapshot.stale {
            peakSinceConsume = 0
            hadFramesSinceConsume = false
            lastFreshPeak = 0
            return AudioLevelSample(peak: 0, freshness: .unavailable, snapshot: snapshot)
        }

        if hadFramesSinceConsume {
            let peak = peakSinceConsume
            peakSinceConsume = 0
            hadFramesSinceConsume = false
            return AudioLevelSample(peak: peak, freshness: .fresh, snapshot: snapshot)
        }

        // No new packet: hold last fresh level (including 0 from a silent packet).
        return AudioLevelSample(peak: lastFreshPeak, freshness: .held, snapshot: snapshot)
    }
}

public enum Timing {
    public static let enabled: Bool =
        ProcessInfo.processInfo.environment["POPCORNHUD_TIMING"] == "1"

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func nowMs() -> UInt64 {
        let info = timebase
        let t = mach_absolute_time()
        return t * UInt64(info.numer) / UInt64(info.denom) / 1_000_000
    }

    public static func log(_ msg: @autoclosure () -> String) {
        guard enabled else { return }
        fputs("[timing] \(msg())\n", stderr)
    }
}
