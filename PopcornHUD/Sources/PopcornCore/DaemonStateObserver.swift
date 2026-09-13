import Darwin
import Dispatch
import Foundation

/// Reads the Voxtype daemon's PID file and checks whether that process is alive.
public enum DaemonProcess {
    /// PID from a PID file, or nil when missing/unparseable.
    public static func readPID(_ path: String) -> Int32? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 32)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n > 0,
              let text = String(bytes: buf.prefix(n), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
        else { return nil }
        return pid
    }

    /// True while the process exists (EPERM still means it exists).
    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Guards against a stale PID file whose number now belongs to an unrelated process, without
    /// tying VoicePop to one install location: Homebrew `voxtype`, `~/Applications/Voxtype.app`, and
    /// dev builds all count. A failed lookup trusts `kill(pid, 0)` so it never hides a live daemon.
    public static func looksLikeVoxtype(_ pid: Int32) -> Bool {
        looksLikeVoxtype(pid, executablePath: ProcessIdentity.executablePath(pid:))
    }

    public static func looksLikeVoxtype(_ pid: Int32, executablePath lookup: (Int32) -> String?) -> Bool {
        guard let path = lookup(pid) else { return true }
        return isVoxtypeExecutable(path)
    }

    /// `voxtype-bin` or `voxtype` anywhere, or any executable inside a `Voxtype.app` bundle.
    public static func isVoxtypeExecutable(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        let name = components.last?.lowercased() ?? ""
        if name == "voxtype-bin" || name == "voxtype" { return true }
        return components.dropLast().contains { $0.caseInsensitiveCompare("Voxtype.app") == .orderedSame }
    }

    /// Voxtype subcommands that are not the long-running daemon (one-shot CLI calls, helpers).
    private static let nonDaemonSubcommands: Set<String> = [
        "menubar", "transcribe", "setup", "config", "info", "configure", "status", "record",
        "meeting", "check-update", "help",
    ]

    /// Whether argv (argv[0] first) starts the daemon: no subcommand (the default) or `daemon`.
    public static func isDaemonInvocation(_ arguments: [String]) -> Bool {
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "-c" || arg == "--config" || arg == "--model" {
                i += 2
                continue
            }
            if arg.hasPrefix("-") {
                i += 1
                continue
            }
            return !nonDaemonSubcommands.contains(arg)
        }
        return true
    }

    /// Live Voxtype daemon processes, whatever their install location and PID file state.
    public static func liveDaemonPIDs() -> [Int32] {
        ProcessIdentity.allPIDs().filter { pid in
            guard let path = ProcessIdentity.executablePath(pid: pid), isVoxtypeExecutable(path),
                  let args = ProcessIdentity.arguments(pid: pid)
            else { return false }
            return isDaemonInvocation(args)
        }
    }

    public static func isLive(pidPath: String = Paths.pid) -> Bool {
        guard let pid = readPID(pidPath) else { return false }
        return isAlive(pid) && looksLikeVoxtype(pid)
    }
}

/// Event-driven observer of the Voxtype runtime directory (`state`, `pid`).
///
/// Uses vnode dispatch sources on the state file, PID file, and runtime directory (or its parent
/// while the directory does not exist) plus a process-exit source on the daemon. Every event
/// triggers one `reconcile`: rebind sources whose inode changed, re-read the PID and state, and
/// publish on change. A one-shot backoff timer (50 ms → 2 s) runs only while some source cannot be
/// registered; healthy observation has no timers at all.
///
/// While the runtime directory is missing, its parent (e.g. `/tmp`) is watched instead. Unrelated
/// churn there would otherwise reconcile on every create/delete by any process, so events from the
/// parent watch are coalesced to at most one reconcile per `parentCoalesceMs` (250 ms). That bounds
/// how late a newly started daemon is noticed, only while it had no runtime directory.
///
/// Rules: no live daemon → `.missing`; a 0-byte read (truncate-then-write in progress) keeps the
/// last state; a PID whose exit was observed stays dead until the PID file is rewritten.
public final class DaemonStateObserver {
    public struct Configuration {
        public var statePath: String
        public var pidPath: String
        /// Directory holding the state/PID files; watched for create/rename/delete.
        public var runtimeDirectory: String
        /// Extra check that a live PID is really the daemon.
        public var pidValidator: (Int32) -> Bool
        /// Opens a descriptor for vnode events (tests inject failures). Returns -1 on failure.
        public var openForEvents: (String) -> Int32
        public var deliveryQueue: DispatchQueue
        public var fallbackInitialMs: Int
        public var fallbackMaxMs: Int
        /// Minimum spacing of reconciles triggered by the parent-directory watch.
        public var parentCoalesceMs: Int

        public init(
            statePath: String = Paths.state,
            pidPath: String = Paths.pid,
            runtimeDirectory: String? = nil,
            pidValidator: @escaping (Int32) -> Bool = DaemonProcess.looksLikeVoxtype,
            openForEvents: @escaping (String) -> Int32 = { open($0, O_EVTONLY | O_CLOEXEC) },
            deliveryQueue: DispatchQueue = .main,
            fallbackInitialMs: Int = 50,
            fallbackMaxMs: Int = 2000,
            parentCoalesceMs: Int = 250
        ) {
            self.statePath = statePath
            self.pidPath = pidPath
            self.runtimeDirectory = runtimeDirectory ?? (statePath as NSString).deletingLastPathComponent
            self.pidValidator = pidValidator
            self.openForEvents = openForEvents
            self.deliveryQueue = deliveryQueue
            self.fallbackInitialMs = fallbackInitialMs
            self.fallbackMaxMs = fallbackMaxMs
            self.parentCoalesceMs = parentCoalesceMs
        }
    }

    public struct Diagnostics: Equatable, Sendable {
        public var stateReads = 0
        public var eventWakeups = 0
        public var fallbackWakeups = 0
        public var reconciles = 0
        /// Parent-directory events folded into an already scheduled reconcile.
        public var coalescedParentEvents = 0
        public var openDescriptors = 0
        public var processSources = 0
        /// False while the fallback timer is armed.
        public var healthy = true
    }

    private struct FileID: Equatable {
        let dev: dev_t
        let ino: ino_t
        /// Distinguishes an in-place PID-file rewrite from the same file.
        let mtime: timespec

        init?(path: String) {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            self.init(st)
        }

        init?(fd: Int32) {
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            self.init(st)
        }

        private init(_ st: stat) {
            dev = st.st_dev
            ino = st.st_ino
            mtime = st.st_mtimespec
        }

        func sameNode(_ other: FileID?) -> Bool {
            guard let other else { return false }
            return dev == other.dev && ino == other.ino
        }

        static func == (a: FileID, b: FileID) -> Bool {
            a.sameNode(b) && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
        }
    }

    private final class Watch {
        let path: String
        let id: FileID
        let source: DispatchSourceFileSystemObject
        init(path: String, id: FileID, source: DispatchSourceFileSystemObject) {
            self.path = path
            self.id = id
            self.source = source
        }
    }

    private let config: Configuration
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    // Queue-confined.
    private var running = false
    private var generation: UInt64 = 0
    private var dirWatch: Watch?
    private var stateWatch: Watch?
    private var pidWatch: Watch?
    private var process: (pid: Int32, source: DispatchSourceProcess)?
    private var exited: (pid: Int32, pidFile: FileID?)?
    private var fallback: DispatchSourceTimer?
    private var fallbackDelayMs: Int
    private var listeners: [(DaemonState) -> Void] = []
    private var diag = Diagnostics()
    private var readBuf = [UInt8](repeating: 0, count: 64)
    private var current: DaemonState = .missing
    private var parentReconcilePending = false

    // Read from any thread.
    private let lock = NSLock()
    private var lockedState: DaemonState = .missing
    private var deliveryEpoch: UInt64 = 0

    public init(configuration: Configuration = Configuration()) {
        config = configuration
        fallbackDelayMs = configuration.fallbackInitialMs
        queue = DispatchQueue(label: "com.caleb.voicepop.state", qos: .userInteractive)
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        onQueue { cancelAll() }
    }

    /// Latest observed state (may be ahead of main-queue deliveries).
    public var state: DaemonState {
        lock.lock()
        defer { lock.unlock() }
        return lockedState
    }

    /// Delivers the current state immediately (asynchronously, on the delivery queue), then every change.
    public func addListener(_ block: @escaping (DaemonState) -> Void) {
        queue.async { [self] in
            listeners.append(block)
            deliver(current, to: [block])
        }
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            generation &+= 1
            fallbackDelayMs = config.fallbackInitialMs
            reconcile(generation)
        }
    }

    /// Synchronous: cancels every source and drops queued deliveries. The observer forgets the
    /// state, so a later `start()` delivers the then-current state again.
    public func stop() {
        onQueue {
            running = false
            generation &+= 1
            current = .missing
            lock.lock()
            deliveryEpoch &+= 1
            lockedState = .missing
            lock.unlock()
            cancelAll()
        }
    }

    /// Forces one authoritative re-read (e.g. after system wake). Cheap; no-op when stopped.
    public func reconcileNow() {
        queue.async { [self] in reconcile(generation) }
    }

    public func diagnostics() -> Diagnostics {
        onQueue { diag }
    }

    /// Waits for already-queued observer work (tests and benchmarks).
    public func waitUntilIdle() {
        onQueue {}
    }

    // MARK: - Reconcile

    private func reconcile(_ gen: UInt64) {
        guard running, gen == generation else { return }
        diag.reconciles += 1
        var healthy = true

        // Runtime directory, or its parent while it does not exist, catches create/rename/delete.
        let runtimeExists = FileID(path: config.runtimeDirectory) != nil
        let dirPath = runtimeExists
            ? config.runtimeDirectory
            : (config.runtimeDirectory as NSString).deletingLastPathComponent
        healthy = bind(&dirWatch, path: dirPath, mask: [.write, .delete, .rename, .revoke, .link], gen: gen,
                       coalesce: !runtimeExists) && healthy
        // Files are watched for in-place writes and for their own deletion/replacement.
        let fileMask: DispatchSource.FileSystemEvent = [.write, .extend, .attrib, .delete, .rename, .revoke]
        healthy = bind(&pidWatch, path: config.pidPath, mask: fileMask, gen: gen, optional: true) && healthy
        healthy = bind(&stateWatch, path: config.statePath, mask: fileMask, gen: gen, optional: true) && healthy

        let live = bindProcess(gen)
        publish(live ? readState() : .missing)

        if healthy {
            fallback?.cancel()
            fallback = nil
            fallbackDelayMs = config.fallbackInitialMs
        } else {
            scheduleFallback(gen)
        }
        diag.healthy = fallback == nil
    }

    /// Keeps `watch` pointed at the current inode of `path`. Returns false when a needed source
    /// could not be registered. `optional` paths may be absent (their creation is seen via the directory).
    private func bind(
        _ watch: inout Watch?,
        path: String,
        mask: DispatchSource.FileSystemEvent,
        gen: UInt64,
        optional: Bool = false,
        coalesce: Bool = false
    ) -> Bool {
        let id = FileID(path: path)
        if let w = watch, w.path == path, w.id.sameNode(id) { return true }
        watch?.source.cancel()
        watch = nil
        guard id != nil else { return optional }
        let fd = config.openForEvents(path)
        guard fd >= 0 else { return false }
        guard let openedID = FileID(fd: fd) else {
            close(fd)
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        diag.openDescriptors += 1
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.diag.eventWakeups += 1
            guard coalesce else {
                self.reconcile(gen)
                return
            }
            guard !self.parentReconcilePending else {
                self.diag.coalescedParentEvents += 1
                return
            }
            self.parentReconcilePending = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(self.config.parentCoalesceMs)) { [weak self] in
                guard let self else { return }
                self.parentReconcilePending = false
                // Current generation: a stop/start while pending must not swallow this event.
                self.reconcile(self.generation)
            }
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.diag.openDescriptors -= 1
        }
        source.resume()
        // If the path was replaced between stat and open we now watch the newer inode; the next
        // reconcile compares against it.
        watch = Watch(path: path, id: openedID, source: source)
        return true
    }

    /// Tracks the daemon PID with a process-exit source. Returns whether the daemon is live.
    private func bindProcess(_ gen: UInt64) -> Bool {
        let pidFile = FileID(path: config.pidPath)
        let pid = pidFile == nil ? nil : DaemonProcess.readPID(config.pidPath)

        if let e = exited, e.pid == pid, e.pidFile == pidFile {
            // Stale PID file left behind by a daemon we saw exit.
            dropProcess()
            return false
        }
        exited = nil

        guard let pid else {
            dropProcess()
            return false
        }
        if let p = process, p.pid == pid {
            return true
        }
        dropProcess()
        guard DaemonProcess.isAlive(pid), config.pidValidator(pid) else { return false }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.running, gen == self.generation, self.process?.pid == pid else { return }
            self.exited = (pid, pidFile)
            self.dropProcess()
            self.reconcile(gen)
        }
        source.resume()
        process = (pid, source)
        diag.processSources += 1
        // Exit between the liveness check and registration would never fire the source.
        if !DaemonProcess.isAlive(pid) {
            exited = (pid, pidFile)
            dropProcess()
            return false
        }
        return true
    }

    private func dropProcess() {
        guard let p = process else { return }
        p.source.cancel()
        process = nil
        diag.processSources -= 1
    }

    private func readState() -> DaemonState {
        let fd = open(config.statePath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .missing }
        defer { close(fd) }
        diag.stateReads += 1
        let n = readBuf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        // Truncate-then-write can yield a 0-byte read; the write that follows fires another event.
        if n == 0 { return current }
        guard n > 0 else { return .missing }
        return .parse(String(bytes: readBuf.prefix(n), encoding: .utf8))
    }

    private func publish(_ next: DaemonState) {
        guard next != current else { return }
        let previous = current
        current = next
        lock.lock()
        lockedState = next
        lock.unlock()
        Timing.event("state.observed", ["from": previous.timingName, "to": next.timingName])
        deliver(next, to: listeners)
    }

    private func deliver(_ value: DaemonState, to callbacks: [(DaemonState) -> Void]) {
        guard !callbacks.isEmpty else { return }
        lock.lock()
        let epoch = deliveryEpoch
        lock.unlock()
        config.deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.deliveryEpoch == epoch
            self.lock.unlock()
            guard valid else { return }
            for cb in callbacks { cb(value) }
        }
    }

    private func scheduleFallback(_ gen: UInt64) {
        guard fallback == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(fallbackDelayMs), leeway: .milliseconds(max(5, fallbackDelayMs / 10)))
        fallbackDelayMs = min(fallbackDelayMs * 2, config.fallbackMaxMs)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.fallback?.cancel()
            self.fallback = nil
            self.diag.fallbackWakeups += 1
            self.reconcile(gen)
        }
        fallback = timer
        timer.resume()
    }

    private func cancelAll() {
        fallback?.cancel()
        fallback = nil
        for w in [dirWatch, stateWatch, pidWatch] { w?.source.cancel() }
        dirWatch = nil
        stateWatch = nil
        pidWatch = nil
        dropProcess()
        exited = nil
        diag.healthy = true
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? body() : queue.sync(execute: body)
    }
}

extension DaemonState {
    /// Stable token for timing logs.
    public var timingName: String {
        switch self {
        case .missing: return "missing"
        case .idle: return "idle"
        case .recording: return "recording"
        case .streaming: return "streaming"
        case .transcribing: return "transcribing"
        case .other: return "other"
        }
    }
}
