import Darwin
import Foundation
import PopcornCore

enum VoxtypeDaemon {
    private static var cachedPid: Int32 = 0
    private static var pidStampMs: UInt64 = 0

    static func isLive() -> Bool {
        let now = Timing.nowMs()
        if cachedPid != 0, now &- pidStampMs <= 1000 {
            if kill(cachedPid, 0) == 0 { return true }
            cachedPid = 0
        }
        guard let raw = try? String(contentsOfFile: Paths.pid, encoding: .utf8) else {
            cachedPid = 0
            return false
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 1 else {
            cachedPid = 0
            return false
        }
        guard kill(pid, 0) == 0 else {
            cachedPid = 0
            return false
        }
        cachedPid = pid
        pidStampMs = now
        return true
    }

    static func engineIsParakeet() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voxtype/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { continue }
            if t.hasPrefix("engine"), t.contains("\"parakeet\"") { return true }
        }
        return false
    }
}

final class StateWatcher {
    private let path: String
    private let queue = DispatchQueue(label: "com.caleb.voicepop.state", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private(set) var state: DaemonState = .missing
    private var listeners: [(DaemonState) -> Void] = []
    private var readBuf = [UInt8](repeating: 0, count: 64)
    private var fastPoll = false

    init(path: String = Paths.state) {
        self.path = path
    }

    func addListener(_ block: @escaping (DaemonState) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.listeners.append(block)
            let current = self.state
            DispatchQueue.main.async { block(current) }
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        applyInterval(t, fast: false)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func applyInterval(_ t: DispatchSourceTimer, fast: Bool) {
        fastPoll = fast
        if fast {
            t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        } else {
            t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        }
    }

    private func tick() {
        let next = readState()
        if next != state {
            state = next
            let cbs = listeners
            DispatchQueue.main.async {
                for cb in cbs { cb(next) }
            }
        }
        let wantFast = next.isHot || next.isTranscribing
        if wantFast != fastPoll, let timer {
            applyInterval(timer, fast: wantFast)
        }
    }

    private func readState() -> DaemonState {
        guard VoxtypeDaemon.isLive() else { return .missing }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return .missing }
        defer { close(fd) }
        let n = readBuf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Int(read(fd, base, raw.count))
        }
        // Truncate-then-write can yield a 0-byte read. Keep the last known
        // state so the HUD does not flash missing/hidden mid-dictation.
        // A hard read error (n < 0) still means the state file is unusable.
        if n == 0 { return state }
        guard n > 0 else { return .missing }
        let s = String(bytes: readBuf.prefix(n), encoding: .utf8)
        return .parse(s)
    }
}
