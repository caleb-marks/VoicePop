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
    /// Connected with levels available, but no new frame - reuse last fresh peak.
    case held
    /// Stale or disconnected - stop driving pops.
    case unavailable
}

public struct AudioLevelSample: Equatable, Sendable {
    public var peak: Float
    public var freshness: AudioLevelFreshness
    public var snapshot: AudioSnapshot
    /// For `.fresh` samples: arrival time of the oldest packet folded into this sample.
    public var oldestPacketMonoMs: UInt64 = 0

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
    /// Arrival time of the oldest packet not yet consumed (0 when none); measures reaction latency.
    public var firstFrameMonoSinceConsume: UInt64 = 0
    public var snapshot = AudioSnapshot.empty

    public init() {}

    public mutating func publish(peak: Float, monoMs: UInt64) {
        let p = peak.isFinite ? max(0, min(1, peak)) : 0
        peakSinceConsume = max(peakSinceConsume, p)
        lastFreshPeak = p
        if !hadFramesSinceConsume { firstFrameMonoSinceConsume = monoMs }
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
        firstFrameMonoSinceConsume = 0
    }

    public mutating func reset() {
        snapshot = .empty
        lastFreshPeak = 0
        peakSinceConsume = 0
        hadFramesSinceConsume = false
        lastFrameMono = 0
        firstFrameMonoSinceConsume = 0
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
            firstFrameMonoSinceConsume = 0
            lastFreshPeak = 0
            return AudioLevelSample(peak: 0, freshness: .unavailable, snapshot: snapshot)
        }

        if hadFramesSinceConsume {
            let peak = peakSinceConsume
            var sample = AudioLevelSample(peak: peak, freshness: .fresh, snapshot: snapshot)
            sample.oldestPacketMonoMs = firstFrameMonoSinceConsume
            peakSinceConsume = 0
            hadFramesSinceConsume = false
            firstFrameMonoSinceConsume = 0
            return sample
        }

        // No new packet: hold last fresh level (including 0 from a silent packet).
        return AudioLevelSample(peak: lastFreshPeak, freshness: .held, snapshot: snapshot)
    }
}

/// Opt-in pipeline timing. Never logs transcript text, app names, or audio levels.
///
/// Enable with `POPCORNHUD_TIMING=1` (also mirrors to stderr) or, for an app launched by
/// Launch Services, `defaults write com.caleb.voicepop VoicePopTiming -bool true` (voxtype-clean
/// reads the same key). Lines go to `~/Library/Logs/VoicePop/timing.log` (directory 0700, file
/// 0600; `VOICEPOP_TIMING_LOG` overrides the path). Format, one event per line:
///
///     2026-09-12T23:47:45.766Z mono=123456.789 proc=hud event=state.observed from=idle to=recording
///
/// `mono` is `mach_absolute_time` in milliseconds, comparable across VoicePop processes.
public enum Timing {
    public static let defaultsDomain = "com.caleb.voicepop"
    public static let defaultsKey = "VoicePopTiming"

    public static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["POPCORNHUD_TIMING"] == "1" { return true }
        return CFPreferencesGetAppBooleanValue(defaultsKey as CFString, defaultsDomain as CFString, nil)
    }()

    private static let mirrorToStderr = ProcessInfo.processInfo.environment["POPCORNHUD_TIMING"] == "1"

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func nowMs() -> UInt64 {
        nowUs() / 1000
    }

    public static func nowUs() -> UInt64 {
        let info = timebase
        return mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom) / 1000
    }

    /// Short process tag used in log lines.
    public static var processTag: String = {
        let name = ProcessInfo.processInfo.processName.lowercased()
        if name.contains("clean") { return "clean" }
        if name.contains("popcornhud") || name.contains("voicepop") { return "hud" }
        return name
    }()

    /// Structured event. Field values must not contain transcript text.
    public static func event(_ name: String, _ fields: @autoclosure () -> KeyValuePairs<String, String> = [:]) {
        guard enabled else { return }
        write(line(name: name, fields: fields(), monoUs: nowUs(), wall: Date()))
    }

    static func line(name: String, fields: KeyValuePairs<String, String>, monoUs: UInt64, wall: Date) -> String {
        var out = wallFormatter.string(from: wall)
        out += " mono=\(monoUs / 1000).\(String(format: "%03d", Int(monoUs % 1000)))"
        out += " proc=\(processTag) event=\(name)"
        for (k, v) in fields {
            out += " \(k)=\(sanitize(v))"
        }
        return out + "\n"
    }

    private static func sanitize(_ v: String) -> String {
        String(v.map { $0 == " " || $0 == "\n" || $0 == "=" ? "_" : $0 })
    }

    private static let wallFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: File sink

    public static var logURL: URL {
        if let override = ProcessInfo.processInfo.environment["VOICEPOP_TIMING_LOG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePop/timing.log")
    }

    private static let sinkLock = NSLock()
    private static var sinkFD: Int32 = -2
    private static var sinkBytes: off_t = 0
    static var rotateBytes: off_t = 32 << 20

    private static func write(_ line: String) {
        if mirrorToStderr { fputs("[timing] \(line)", stderr) }
        append(line, to: logURL)
    }

    /// Appends one line, opening the sink on first use and rotating by a byte counter, since a
    /// long-running HUD writes every frame while recording (rotating only at open is not enough).
    static func append(_ line: String, to url: URL) {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        if sinkFD == -2 { openTrackedSink(url) }
        guard sinkFD >= 0 else { return }
        // One write per line: O_APPEND keeps concurrent HUD and voxtype-clean lines whole.
        let written = line.utf8CString.withUnsafeBufferPointer { Darwin.write(sinkFD, $0.baseAddress, $0.count - 1) }
        if written > 0 { sinkBytes += off_t(written) }
        if sinkBytes > rotateBytes {
            close(sinkFD)
            openTrackedSink(url)
        }
    }

    /// Lock held. Opens (rotating when already over size) and seeds the counter with the file size.
    private static func openTrackedSink(_ url: URL) {
        sinkFD = openSink(url)
        var st = stat()
        sinkBytes = sinkFD >= 0 && fstat(sinkFD, &st) == 0 ? st.st_size : 0
    }

    /// Tests: forget the open sink so the next `append` opens `url` afresh.
    static func resetSinkForTesting() {
        sinkLock.lock()
        if sinkFD >= 0 { close(sinkFD) }
        sinkFD = -2
        sinkBytes = 0
        sinkLock.unlock()
    }

    /// Creates the private log (dir 0700, file 0600), rotating once past `rotateBytes`.
    static func openSink(_ url: URL) -> Int32 {
        let dir = url.deletingLastPathComponent().path
        if mkdir(dir, 0o700) != 0, errno != EEXIST { return -1 }
        var st = stat()
        if stat(url.path, &st) == 0, st.st_size > rotateBytes {
            _ = rename(url.path, url.path + ".1")
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return -1 }
        _ = fchmod(fd, 0o600)
        return fd
    }
}
