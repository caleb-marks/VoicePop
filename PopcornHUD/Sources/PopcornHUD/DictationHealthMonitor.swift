import AppKit
import PopcornCore

extension Notification.Name {
    /// Posted on main by `EngineControl.record`; `userInfo["command"]` is the raw command.
    static let voicePopRecordRequested = Notification.Name("VoicePopRecordRequested")
}

/// Publishes `DictationStatus` (daemon state + engine facts) to main-queue listeners.
/// The menu, Settings, onboarding, and HUD read status only through this type; they never probe
/// the engine on the main thread.
///
/// Facts come from:
/// - `EngineProbe` (off main, bounded): engine installed/usable, configured model installed.
///   Runs at start, on `refresh()`, on app activation (≤ once per 30 s), after wake, and when the
///   daemon appears or disappears (≤ once per 2 s). Overlapping requests coalesce into one rerun.
/// - `DictationSessionTracker`: failures and microphone evidence from state changes, the
///   transcript-ready signal, menu record requests, and per-recording levels from the HUD. One
///   one-shot timer is armed only while the tracker has a pending deadline.
final class DictationHealthMonitor {
    /// Returned by the `add…Listener` methods; pass to `removeListener(_:)`.
    struct ListenerToken: Hashable {
        fileprivate let id: Int
    }

    private let watcher: StateWatcher
    private let probe: () -> EngineProbeResult
    private let probeQueue = DispatchQueue(label: "com.caleb.voicepop.health", qos: .utility)
    /// Serial so a session's baseline read always completes before its later history checks.
    private let historyQueue = DispatchQueue(label: "com.caleb.voicepop.health.history", qos: .utility)
    /// historyQueue-confined: last history entry when the current recording started.
    private var historyBaseline: (start: Date, snapshot: HistorySnapshot)?
    private var listeners: [(id: Int, block: (DictationStatus) -> Void)] = []
    private var transcriptReadyListeners: [(id: Int, block: () -> Void)] = []
    private var historyAppendedListeners: [(id: Int, block: () -> Void)] = []
    private var nextListenerID = 0
    /// Wall-clock start of the current or last recording, to match history entries to it.
    private var sessionStart: Date?
    private var facts = EngineFacts()
    private(set) var status = DictationStatus(daemon: .missing, facts: EngineFacts())

    private var tracker = DictationSessionTracker()
    private var trackerFailure: DictationFailure?
    private var trackerMicrophoneSilent = false
    private var deadline: DispatchSourceTimer?
    private var probeInFlight = false
    private var probeQueued = false
    private var lastProbeMs: UInt64?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false

    init(watcher: StateWatcher, probe: @escaping () -> EngineProbeResult = EngineProbe.probe) {
        self.watcher = watcher
        self.probe = probe
    }

    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        deadline?.cancel()
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Main thread. Calls `block` immediately with the current status, then on every change.
    @discardableResult
    func addListener(_ block: @escaping (DictationStatus) -> Void) -> ListenerToken {
        let token = makeToken()
        listeners.append((token.id, block))
        block(status)
        return token
    }

    /// Main thread. voxtype-clean finished a transcript (before Voxtype types it). One Darwin
    /// observer here fans the signal out, so other components need not register their own.
    @discardableResult
    func addTranscriptReadyListener(_ block: @escaping () -> Void) -> ListenerToken {
        let token = makeToken()
        transcriptReadyListeners.append((token.id, block))
        return token
    }

    /// Main thread. voxtype-clean appended the dictation to history (`HistoryStore.last()` is current).
    @discardableResult
    func addHistoryAppendedListener(_ block: @escaping () -> Void) -> ListenerToken {
        let token = makeToken()
        historyAppendedListeners.append((token.id, block))
        return token
    }

    /// Main thread. Removes a listener added by any `add…Listener` method; unknown tokens are ignored.
    func removeListener(_ token: ListenerToken) {
        listeners.removeAll { $0.id == token.id }
        transcriptReadyListeners.removeAll { $0.id == token.id }
        historyAppendedListeners.removeAll { $0.id == token.id }
    }

    private func makeToken() -> ListenerToken {
        nextListenerID += 1
        return ListenerToken(id: nextListenerID)
    }

    /// Main thread.
    func start() {
        guard !started else { return }
        started = true
        watcher.addListener { [weak self] state in
            self?.daemonChanged(state)
        }
        observe(NotificationCenter.default, .voicePopRecordRequested) { [weak self] note in
            guard let self, let raw = note.userInfo?["command"] as? String else { return }
            self.tracker.recordRequested(start: raw == "start" || raw == "toggle", atMs: Timing.nowMs())
            self.syncTracker()
        }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.requestProbe(minIntervalMs: 30_000)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.requestProbe(minIntervalMs: 5000)
        }
        for signal in [VoicePopSignal.transcriptReady, VoicePopSignal.historyAppended] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let monitor = Unmanaged<DictationHealthMonitor>.fromOpaque(observer).takeUnretainedValue()
                    let signal = name.rawValue as String
                    DispatchQueue.main.async { monitor.darwinSignal(signal) }
                },
                signal as CFString,
                nil,
                .deliverImmediately
            )
        }
        refresh()
    }

    /// Re-probe engine/model facts off the main thread (e.g. after setup or a model switch).
    func refresh() {
        EngineProbe.invalidateCache()
        requestProbe(minIntervalMs: 0)
    }

    /// Model downloads started from Settings or onboarding report progress here. nil clears.
    func noteModelDownload(_ download: EngineFacts.Download?) {
        let finished = download == nil && facts.download != nil
        update { $0.download = download }
        if finished { refresh() }
    }

    /// The HUD reports whether microphone levels are arriving while recording.
    func noteAudioLevels(available: Bool) {
        guard status.daemon.isHot || available else { return }
        update { $0.audioLevelsUnavailable = !available }
    }

    /// The HUD reports level statistics once per finished recording (evidence for microphone access).
    func noteRecordingLevels(frames: Int, maxPeak: Float, durationMs: UInt64) {
        tracker.recordingLevels(frames: frames, maxPeak: maxPeak, durationMs: durationMs)
        syncTracker()
    }

    /// Main thread.
    func update(_ change: (inout EngineFacts) -> Void) {
        var next = facts
        change(&next)
        guard next != facts else { return }
        facts = next
        publish(daemon: status.daemon)
    }

    // MARK: - Inputs

    private func daemonChanged(_ state: DaemonState) {
        let previous = status.daemon
        if state.isHot, !previous.isHot {
            let start = Date()
            sessionStart = start
            historyQueue.async { [weak self] in
                self?.historyBaseline = (start, HistorySnapshot(last: HistoryStore.last()))
            }
        }
        tracker.stateChanged(state, atMs: Timing.nowMs())
        if !state.isHot { facts.audioLevelsUnavailable = false }
        syncTracker(daemon: state)
        // A daemon (re)appearing or vanishing is when installs and model switches take effect.
        if (previous == .missing) != (state == .missing) {
            requestProbe(minIntervalMs: 2000)
        }
    }

    private func darwinSignal(_ signal: String) {
        switch signal {
        case VoicePopSignal.transcriptReady:
            tracker.transcriptReady(atMs: Timing.nowMs())
            syncTracker()
            transcriptReadyListeners.forEach { $0.block() }
        case VoicePopSignal.historyAppended:
            if trackerFailure != nil { checkHistoryForFailedSession() }
            historyAppendedListeners.forEach { $0.block() }
        default:
            break
        }
    }

    /// Off main: does history hold text from the failed dictation? Only then is copy offered.
    private func checkHistoryForFailedSession() {
        guard let failure = trackerFailure, failure != .didNotStart, let start = sessionStart else { return }
        historyQueue.async { [weak self] in
            guard let self else { return }
            let baseline = self.historyBaseline.flatMap { $0.start == start ? $0.snapshot : nil }
            let hasText = DictationSessionTracker.historyEntry(HistoryStore.last(), isFromSessionStartedAt: start, baseline: baseline)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.trackerFailure == failure, self.sessionStart == start else { return }
                self.update { $0.lastFailureHasText = hasText }
            }
        }
    }

    private func syncTracker(daemon: DaemonState? = nil) {
        // Only overwrite facts the tracker changed, so other writers of `update` are preserved.
        var failureChanged = false
        if tracker.failure != trackerFailure {
            trackerFailure = tracker.failure
            facts.lastFailure = tracker.failure?.rawValue
            facts.lastFailureHasText = false
            failureChanged = true
        }
        if tracker.microphoneSilent != trackerMicrophoneSilent {
            trackerMicrophoneSilent = tracker.microphoneSilent
            facts.permissionsNeeded = tracker.microphoneSilent
            facts.permissionHint = tracker.microphoneSilent ? .microphone : nil
        }
        publish(daemon: daemon ?? status.daemon)
        armDeadline()
        if failureChanged { checkHistoryForFailedSession() }
    }

    private func armDeadline() {
        deadline?.cancel()
        deadline = nil
        guard let due = tracker.nextDeadlineMs else { return }
        let now = Timing.nowMs()
        let delay = due > now ? Int(due - now) : 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(delay), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.tracker.tick(atMs: Timing.nowMs())
            self.syncTracker()
        }
        deadline = timer
        timer.resume()
    }

    // MARK: - Probing

    private func requestProbe(minIntervalMs: UInt64) {
        if minIntervalMs > 0, let last = lastProbeMs, Timing.nowMs() &- last < minIntervalMs { return }
        guard !probeInFlight else {
            probeQueued = true
            return
        }
        probeInFlight = true
        let probe = self.probe
        probeQueue.async { [weak self] in
            let started = Timing.nowMs()
            let result = probe()
            Timing.event("health.probe", ["ms": String(Timing.nowMs() - started)])
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    private func apply(_ result: EngineProbeResult) {
        probeInFlight = false
        lastProbeMs = Timing.nowMs()
        tracker.transcriptSignalExpected = result.postProcessIsVoicePop ?? false
        update { f in
            f.engineInstalled = result.engineUsable
            f.engineProblem = result.binaryInstalled && !result.engineUsable
                ? "This Voxtype build can’t run the \(result.configuredEngine ?? "configured") engine."
                : nil
            f.modelInstalled = result.modelInstalled
            f.modelTitle = result.configuredModel.map { VoxtypeModel.title(for: $0) }
            f.configuredModel = result.configuredModel
        }
        if probeQueued {
            probeQueued = false
            requestProbe(minIntervalMs: 0)
        }
    }

    // MARK: - Publishing

    private func publish(daemon: DaemonState) {
        let next = DictationStatus(daemon: daemon, facts: facts)
        guard next != status else { return }
        if next.issue != status.issue {
            Timing.event("health.issue", ["issue": next.issue.map { String(describing: $0).split(separator: "(").first.map(String.init) ?? "" } ?? "none"])
        }
        status = next
        for listener in listeners { listener.block(next) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: block)))
    }
}
