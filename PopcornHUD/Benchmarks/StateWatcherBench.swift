import Darwin
import Foundation
import PopcornCore

// Synthetic, isolated comparison of daemon-state observation strategies.
// Uses a temporary runtime directory, a `/bin/sleep` child as the fake daemon PID, and
// Rust-`fs::write`-style truncate+write updates. Never touches /tmp/voxtype.
//
//   state-watcher-bench latency  [--impl polling|event|both] [--cycles N] [--seed S]
//   state-watcher-bench idle     [--impl polling|event] [--seconds S]
//   state-watcher-bench scenarios
//   state-watcher-bench lifecycle [--cycles N]

// MARK: - Watchers under test

protocol BenchWatcher: AnyObject {
    var name: String { get }
    func addListener(_ block: @escaping (DaemonState) -> Void)
    func start()
    func stop()
    /// State-file reads and handler wakeups so far.
    func counters() -> (reads: Int, wakeups: Int)
}

/// Faithful copy of the pre-polish `StateWatcher` + `VoxtypeDaemon.isLive` (base commit f21e2fb):
/// 100 ms idle / 8 ms hot timer, PID cached for 1 s, 0-byte reads keep the last state.
final class LegacyPollingWatcher: BenchWatcher {
    let name = "polling"
    private let path: String
    private let pidPath: String
    private let queue = DispatchQueue(label: "bench.polling", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var state: DaemonState = .missing
    private var listeners: [(DaemonState) -> Void] = []
    private var readBuf = [UInt8](repeating: 0, count: 64)
    private var fastPoll = false
    private var cachedPid: Int32 = 0
    private var pidStampMs: UInt64 = 0
    private var reads = 0
    private var wakeups = 0

    init(path: String, pidPath: String) {
        self.path = path
        self.pidPath = pidPath
    }

    func counters() -> (reads: Int, wakeups: Int) { queue.sync { (reads, wakeups) } }

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
        queue.sync {
            timer?.cancel()
            timer = nil
        }
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
        wakeups += 1
        let next = readState()
        if next != state {
            state = next
            let cbs = listeners
            DispatchQueue.main.async { for cb in cbs { cb(next) } }
        }
        let wantFast = next.isHot || next.isTranscribing
        if wantFast != fastPoll, let timer { applyInterval(timer, fast: wantFast) }
    }

    private func isLive() -> Bool {
        let now = Timing.nowMs()
        if cachedPid != 0, now &- pidStampMs <= 1000 {
            if kill(cachedPid, 0) == 0 { return true }
            cachedPid = 0
        }
        guard let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
              kill(pid, 0) == 0
        else {
            cachedPid = 0
            return false
        }
        cachedPid = pid
        pidStampMs = now
        return true
    }

    private func readState() -> DaemonState {
        guard isLive() else { return .missing }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return .missing }
        defer { close(fd) }
        reads += 1
        let n = readBuf.withUnsafeMutableBytes { raw -> Int in
            Int(read(fd, raw.baseAddress, raw.count))
        }
        if n == 0 { return state }
        guard n > 0 else { return .missing }
        return .parse(String(bytes: readBuf.prefix(n), encoding: .utf8))
    }
}

final class EventWatcher: BenchWatcher {
    let name = "event"
    let observer: DaemonStateObserver

    init(path: String, pidPath: String) {
        observer = DaemonStateObserver(configuration: .init(statePath: path, pidPath: pidPath, pidValidator: { _ in true }))
    }

    func addListener(_ block: @escaping (DaemonState) -> Void) { observer.addListener(block) }
    func start() { observer.start() }
    func stop() { observer.stop() }
    func counters() -> (reads: Int, wakeups: Int) {
        let d = observer.diagnostics()
        return (d.stateReads, d.eventWakeups + d.fallbackWakeups)
    }
}

func makeWatcher(_ impl: String, _ f: Fixture) -> BenchWatcher {
    impl == "event" ? EventWatcher(path: f.statePath, pidPath: f.pidPath)
        : LegacyPollingWatcher(path: f.statePath, pidPath: f.pidPath)
}

// MARK: - Fixture

final class Fixture {
    let base: URL
    let runtime: URL
    var statePath: String { runtime.appendingPathComponent("state").path }
    var pidPath: String { runtime.appendingPathComponent("pid").path }
    private(set) var child: Process?

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voicepop-state-bench-\(getpid())-\(UUID().uuidString.prefix(8))")
        runtime = base.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    }

    func launchDaemon(state: String = "idle") throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["3600"]
        try p.run()
        child = p
        writeState(state)
        writeFile(pidPath, "\(p.processIdentifier)\n")
    }

    func killDaemon() {
        child?.terminate()
        child?.waitUntilExit()
        child = nil
    }

    /// Same syscall shape as Rust `std::fs::write`: open(O_TRUNC) then write.
    func writeState(_ s: String) { writeFile(statePath, s) }

    func writeFile(_ path: String, _ s: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        precondition(fd >= 0, "open \(path) failed: \(errno)")
        _ = s.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
        close(fd)
    }

    func atomicWriteState(_ s: String) {
        let tmp = runtime.appendingPathComponent(".state.tmp").path
        writeFile(tmp, s)
        precondition(rename(tmp, statePath) == 0)
    }

    func cleanup() {
        killDaemon()
        try? FileManager.default.removeItem(at: base)
    }
}

// MARK: - Helpers

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

struct LCG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
}

func fmt(_ v: Double) -> String { v.isNaN ? "-" : String(format: "%.2f", v) }

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
        + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

/// Runs the main run loop (so main-queue deliveries happen) until `condition` or `seconds`.
func spin(_ seconds: Double, until condition: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !condition() {
        RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.005)))
    }
}

func arg(_ name: String, _ fallback: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return fallback
}

/// Records write→main-listener latency for the one transition currently pending.
final class LatencyProbe {
    private let lock = NSLock()
    private var pending: (label: String, state: DaemonState, t: UInt64)?
    private(set) var samples: [String: [Double]] = [:]
    private(set) var missed: [String: Int] = [:]
    private var seen = false

    func arm(_ label: String, _ state: DaemonState) {
        lock.lock()
        if let p = pending, !seen { missed[p.label, default: 0] += 1 }
        pending = (label, state, nowNs())
        seen = false
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if let p = pending, !seen { missed[p.label, default: 0] += 1 }
        pending = nil
        lock.unlock()
    }

    func observe(_ state: DaemonState) {
        let t = nowNs()
        lock.lock()
        defer { lock.unlock() }
        guard let p = pending, !seen, p.state == state else { return }
        seen = true
        samples[p.label, default: []].append(Double(t - p.t) / 1e6)
    }

    func waitSeen(timeout: Double) -> Bool {
        var ok = false
        spin(timeout) {
            lock.lock(); ok = seen; lock.unlock()
            return ok
        }
        return ok
    }
}

// MARK: - Modes

@main
enum StateWatcherBench {
    static func main() throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "latency"
        print("# state-watcher-bench \(mode) — synthetic isolated fixture; \(machine())")
        switch mode {
        case "latency": try latency()
        case "idle": try idle()
        case "scenarios": try scenarios()
        case "lifecycle": try lifecycle()
        default:
            print("unknown mode \(mode)")
            exit(2)
        }
    }

    static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(String(cString: buf)), macOS \(os), -O"
    }

    /// Realistic dictation cycles: idle dwell → recording → transcribing → idle, random dwell so
    /// the write phase is uncorrelated with any poll phase.
    static func latency() throws {
        let impl = arg("--impl", "both")
        let cycles = Int(arg("--cycles", "60"))!
        var rng = LCG(s: UInt64(arg("--seed", "7"))!)
        let f = try Fixture()
        defer { f.cleanup() }
        try f.launchDaemon()

        let impls = impl == "both" ? ["polling", "event"] : [impl]
        var watchers: [(BenchWatcher, LatencyProbe)] = []
        for name in impls {
            let w = makeWatcher(name, f)
            let probe = LatencyProbe()
            w.addListener { probe.observe($0) }
            watchers.append((w, probe))
        }
        watchers.forEach { $0.0.start() }
        spin(0.5)
        let reads0 = watchers.map { $0.0.counters() }
        let cpu0 = cpuSeconds()
        let started = Date()

        let steps: [(String, DaemonState, ClosedRange<Double>)] = [
            ("recording", .recording, 0.5...1.5),
            ("transcribing", .transcribing, 0.1...0.4),
            ("idle", .idle, 0.3...1.5),
        ]
        for _ in 0..<cycles {
            for (raw, state, dwell) in steps {
                let label = "→\(raw)"
                watchers.forEach { $0.1.arm(label, state) }
                f.writeState(raw)
                spin(rng.range(dwell.lowerBound, dwell.upperBound))
            }
        }
        watchers.forEach { $0.1.finish() }
        let elapsed = Date().timeIntervalSince(started)
        let cpu = cpuSeconds() - cpu0

        print("cycles=\(cycles) transitions=\(cycles * 3) wall=\(fmt(elapsed))s processCPU=\(fmt(cpu))s (all watchers + writer)")
        print("impl      transition     n   p50ms   p95ms   maxms  missed")
        for (i, (w, probe)) in watchers.enumerated() {
            for (label, _, _) in steps.map({ ("→\($0.0)", $0.1, $0.2) }) {
                let s = probe.samples[label] ?? []
                print(String(format: "%-9@ %-13@ %3d %7@ %7@ %7@ %5d",
                             w.name as NSString, label as NSString, s.count,
                             fmt(percentile(s, 0.5)) as NSString, fmt(percentile(s, 0.95)) as NSString,
                             fmt(s.max() ?? .nan) as NSString, probe.missed[label] ?? 0))
            }
            let all = probe.samples.values.flatMap { $0 }
            let c = w.counters()
            print(String(format: "%-9@ %-13@ %3d %7@ %7@ %7@   reads=%d wakeups=%d",
                         w.name as NSString, "all" as NSString, all.count,
                         fmt(percentile(all, 0.5)) as NSString, fmt(percentile(all, 0.95)) as NSString,
                         fmt(all.max() ?? .nan) as NSString, c.reads - reads0[i].reads, c.wakeups - reads0[i].wakeups))
        }
        watchers.forEach { $0.0.stop() }
    }

    /// Unchanged idle state: reads, wakeups, and process CPU for one implementation alone.
    static func idle() throws {
        let impl = arg("--impl", "polling")
        let seconds = Double(arg("--seconds", "10"))!
        let f = try Fixture()
        defer { f.cleanup() }
        try f.launchDaemon()
        let w = makeWatcher(impl, f)
        var callbacks = 0
        w.addListener { _ in callbacks += 1 }
        w.start()
        spin(0.5)
        let c0 = w.counters()
        let cb0 = callbacks
        let cpu0 = cpuSeconds()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let cpu = cpuSeconds() - cpu0
        let c = w.counters()
        print("impl=\(impl) idleSeconds=\(fmt(seconds)) reads=\(c.reads - c0.reads) wakeups=\(c.wakeups - c0.wakeups) callbacks=\(callbacks - cb0) processCPUms=\(fmt(cpu * 1000))")
        w.stop()
    }

    /// Filesystem/process edge cases, event watcher only: latency to the expected state.
    static func scenarios() throws {
        let impl = arg("--impl", "event")
        let f = try Fixture()
        defer { f.cleanup() }
        try f.launchDaemon()
        let w = makeWatcher(impl, f)
        let probe = LatencyProbe()
        w.addListener { probe.observe($0) }
        w.start()
        spin(0.3)

        func step(_ label: String, _ expected: DaemonState, _ action: () throws -> Void) rethrows {
            probe.arm(label, expected)
            try action()
            let ok = probe.waitSeen(timeout: 3)
            let ms = probe.samples[label]?.last ?? .nan
            print(String(format: "%-34@ %@ %@ ms", label as NSString, (ok ? "ok  " : "MISS") as NSString, fmt(ms) as NSString))
            spin(0.05)
        }

        step("truncate+write → recording", .recording) { f.writeState("recording") }
        step("atomic rename → transcribing", .transcribing) { f.atomicWriteState("transcribing") }
        try step("delete state → missing", .missing) { try FileManager.default.removeItem(atPath: f.statePath) }
        step("recreate state → idle", .idle) { f.writeState("idle") }
        step("daemon exit → missing", .missing) { f.killDaemon() }
        try step("new daemon pid → idle", .idle) { try f.launchDaemon(state: "idle") }
        try step("remove runtime dir → missing", .missing) { try FileManager.default.removeItem(at: f.runtime) }
        try step("recreate runtime dir → recording", .recording) {
            f.killDaemon()
            try FileManager.default.createDirectory(at: f.runtime, withIntermediateDirectories: true)
            try f.launchDaemon(state: "recording")
        }
        w.stop()
    }

    static func lifecycle() throws {
        let cycles = Int(arg("--cycles", "100"))!
        let f = try Fixture()
        defer { f.cleanup() }
        try f.launchDaemon()
        let w = EventWatcher(path: f.statePath, pidPath: f.pidPath)
        let fdsBefore = openFDCount()
        var maxDescriptors = 0
        for _ in 0..<cycles {
            w.start()
            w.observer.waitUntilIdle()
            maxDescriptors = max(maxDescriptors, w.observer.diagnostics().openDescriptors)
            w.stop()
        }
        w.observer.waitUntilIdle()
        spin(0.1)
        print("cycles=\(cycles) maxWatcherDescriptors=\(maxDescriptors) finalWatcherDescriptors=\(w.observer.diagnostics().openDescriptors) processFDsBefore=\(fdsBefore) after=\(openFDCount())")
    }

    static func openFDCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
}
