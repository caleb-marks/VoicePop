import AppKit
import CoreFoundation
import os
import SwiftUI
import PopcornArt
import PopcornCore

/// HUD lifecycle and animation scheduling.
///
/// Work happens only while the HUD is shown: the display link (or 60 Hz timer fallback), audio
/// socket, simulation, and SwiftUI host all stop and detach when hidden. Recording feedback starts
/// only from a daemon recording state, and the first frame is published synchronously on entry
/// rather than waiting for the next display-link callback.
final class HUDController {
    /// Delay before "Audio levels unavailable" is shown: the socket connects and the first frame
    /// arrives shortly after recording starts, and a flash of the warning would be noise.
    private static let levelsGraceMs: UInt64 = 600
    /// If the display link has not ticked by then (no active display, reconfiguration), use the timer.
    private static let displayLinkWatchdogMs = 300

    private let audio = AudioSocketReader()
    private let sim = PopcornSim()

    private var panel: NSPanel?
    private var hosting: NSHostingView<PopcornView>?
    private var displayLink: CVDisplayLink?
    private var timerFallback: DispatchSourceTimer?

    private var presentation: HUDPresentation = .hidden
    private var opacity: Double = 0
    private var scale: Double = 0.90
    private var label: String = "Recording"
    private var detail: String = ""
    private var enterProgress: Double = 0
    private var collapseProgress: Double = 0
    private var reduceMotion = false
    private var lastPublish: PopcornFrame?
    private var animating = false
    private var lastAnimMonoMs: UInt64?
    private let tickPending = OSAllocatedUnfairLock(initialState: false)
    private var capsuleFrozen = false
    private var lastPublishMonoMs: UInt64 = 0
    private var mascot: Mascot = .popcorn
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Rounded-up backing scales whose kernel sprites were already prewarmed (main thread).
    private var prewarmedScales: Set<Int> = []
    private var health: DictationHealthMonitor?

    // Recording session bookkeeping (main thread).
    private var recordingEnteredMs: UInt64 = 0
    private var levelsReportedUnavailable = false
    private var animationStartedMs: UInt64 = 0
    private var ticksSinceAnimationStart = 0
    // Timing instrumentation (only used when Timing.enabled).
    private var awaitingFirstVisible = false
    private var awaitingFirstFrame = false
    private var oldestUnshownPacketMs: UInt64 = 0

    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        stopAnimation()
        audio.stop()
        panel?.orderOut(nil)
    }

    private func transcriptReady() {
        guard presentation == .transcribing else { return }
        Timing.event("transcript.ready")
        beginHide()
    }

    func start(watcher: StateWatcher, health: DictationHealthMonitor) {
        self.health = health
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if Timing.enabled {
            PopcornView.drawCostHook = { Timing.event("hud.draw", ["us": String($0)]) }
        }
        observe(DistributedNotificationCenter.default(), NSNotification.Name("AppleInterfaceThemeChangedNotification")) { [weak self] _ in
            self?.positionPanel()
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            guard let self else { return }
            self.positionPanel()
            self.prewarmSprites()
            // The display link was bound to the displays active when it started.
            self.restartAnimationClock(reason: "screens")
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.restartAnimationClock(reason: "wake")
        }
        observe(NotificationCenter.default, .voicePopMascotDidChange) { [weak self] note in
            guard let self else { return }
            if let next = note.object as? Mascot {
                self.mascot = next
            } else {
                self.mascot = StylePrefsCache.current().mascot
            }
            if self.presentation != .hidden, let last = self.lastPublish {
                var updated = last
                updated.scene.mascot = self.mascot
                self.lastPublish = updated
                self.hosting?.rootView = PopcornView(frame: updated)
            }
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.sim.reduceMotion = self.reduceMotion
            if self.reduceMotion { self.scale = 1 }
        }

        health.addTranscriptReadyListener { [weak self] in
            self?.transcriptReady()
        }

        buildPanel()
        prewarmSprites()
        watcher.addListener { [weak self] state in
            self?.handleState(state)
        }
        fputs("VoicePop started\n", stderr)
    }

    /// Paints kernel sprites for each connected display scale off main, so the first recording
    /// frame does not rasterize them. The sprite cache is lock-protected and a cold cache still
    /// draws correctly (painting on demand), so this only moves work earlier.
    private func prewarmSprites() {
        let scales = Set(NSScreen.screens.map { Int($0.backingScaleFactor.rounded(.up)) })
            .subtracting(prewarmedScales)
        guard !scales.isEmpty else { return }
        prewarmedScales.formUnion(scales)
        DispatchQueue.global(qos: .utility).async {
            for scale in scales.sorted(by: >) {
                let start = Timing.nowUs()
                PopcornRenderer.prewarmKernelSprites(displayScale: CGFloat(scale))
                Timing.event("hud.prewarm", ["scale": String(scale), "ms": String((Timing.nowUs() - start) / 1000)])
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: block)))
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Tunables.cardW, height: Tunables.cardH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel
        positionPanel()
    }

    private func attachHost() {
        if hosting != nil { return }
        if panel == nil { buildPanel() }
        guard let panel else { return }
        let empty = PopcornFrame(
            opacity: 0, scale: 0.9,
            scene: .still(label: "", presentation: .hidden, reduceMotion: reduceMotion, mascot: mascot, bagVisible: 1)
        )
        let host = NSHostingView(rootView: PopcornView(frame: empty))
        host.frame = NSRect(x: 0, y: 0, width: Tunables.cardW, height: Tunables.cardH)
        panel.contentView = host
        hosting = host
    }

    private func detachHost() {
        hosting?.removeFromSuperview()
        hosting = nil
        panel?.contentView = nil
        lastPublish = nil
    }

    private func positionPanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let vf = screen.visibleFrame
        let x = vf.midX - Tunables.cardW / 2
        let y = vf.minY + Tunables.marginPx
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.setContentSize(NSSize(width: Tunables.cardW, height: Tunables.cardH))
    }

    private func handleState(_ state: DaemonState) {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if state.isHot {
            label = state.statusLabel
            detail = ""
            if presentation != .recording {
                enterRecording()
            }
        } else if state.isTranscribing {
            beginTranscribing()
        } else {
            beginHide()
        }
    }

    private func enterRecording() {
        mascot = StylePrefsCache.current().mascot
        presentation = .recording
        enterProgress = 0
        collapseProgress = 0
        opacity = 0
        scale = 0.90
        lastAnimMonoMs = nil
        lastPublishMonoMs = 0
        capsuleFrozen = false
        recordingEnteredMs = Timing.nowMs()
        levelsReportedUnavailable = false
        awaitingFirstVisible = Timing.enabled
        awaitingFirstFrame = false
        oldestUnshownPacketMs = 0
        sim.reset()
        sim.allowSpawn = true
        sim.reduceMotion = reduceMotion
        sim.setBagVisible(1)
        audio.start()
        attachHost()
        positionPanel()
        panel?.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: label as NSString,
            .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
        Timing.event("hud.enter")
        startAnimation()
        // Publish the first frame now instead of up to one display interval later.
        tick()
    }

    /// Reports the finished recording's level statistics once, when it leaves `.recording`.
    private func endRecordingSession() {
        guard presentation == .recording else { return }
        let stats = audio.sessionStats()
        let duration = Timing.nowMs() &- recordingEnteredMs
        health?.noteRecordingLevels(frames: stats.frames, maxPeak: stats.maxPeak, durationMs: duration)
        if levelsReportedUnavailable {
            levelsReportedUnavailable = false
            health?.noteAudioLevels(available: true)
        }
    }

    private func beginTranscribing() {
        guard presentation == .recording || presentation == .transcribing else { return }
        endRecordingSession()
        presentation = .transcribing
        label = "Transcribing…"
        detail = ""
        sim.allowSpawn = false
        audio.stop()
        collapseProgress = 0
        lastAnimMonoMs = nil
        capsuleFrozen = false
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Transcribing" as NSString,
            .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
        startAnimation()
        Timing.event("hud.transcribing")
    }

    private func beginHide() {
        endRecordingSession()
        audio.stop()
        sim.allowSpawn = false
        capsuleFrozen = false
        if presentation == .hidden {
            stopAnimation()
            return
        }
        // Neutral dismiss - no success
        presentation = .hidden
        opacity = 0
        scale = 0.90
        sim.reset()
        panel?.orderOut(nil)
        stopAnimation()
        detachHost()
        Timing.event("hud.hidden")
    }

    // MARK: - Animation clock

    private func startAnimation() {
        guard !animating else { return }
        animating = true
        tickPending.withLock { $0 = false }
        animationStartedMs = Timing.nowMs()
        ticksSinceAnimationStart = 0
        if startDisplayLink() {
            armDisplayLinkWatchdog()
        } else {
            startTimerFallback()
        }
    }

    private func stopAnimation() {
        animating = false
        tickPending.withLock { $0 = false }
        lastAnimMonoMs = nil
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        timerFallback?.cancel()
        timerFallback = nil
    }

    /// Rebinds the clock after display reconfiguration or wake. No-op while hidden.
    private func restartAnimationClock(reason: String) {
        guard animating else { return }
        Timing.event("hud.clock", ["reason": reason])
        stopAnimation()
        startAnimation()
    }

    private func startDisplayLink() -> Bool {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            return false
        }
        // Follow the HUD's display so ticks line up with its refresh.
        if let number = panel?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            CVDisplayLinkSetCurrentCGDisplay(link, CGDirectDisplayID(number.uint32Value))
        }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let ctrl = Unmanaged<HUDController>.fromOpaque(userInfo!).takeUnretainedValue()
            ctrl.scheduleTick()
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        guard CVDisplayLinkStart(link) == kCVReturnSuccess else { return false }
        displayLink = link
        return true
    }

    private func armDisplayLinkWatchdog() {
        let started = animationStartedMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.displayLinkWatchdogMs)) { [weak self] in
            guard let self, self.animating, self.animationStartedMs == started,
                  self.displayLink != nil, self.ticksSinceAnimationStart <= 1 else { return }
            Timing.event("hud.clock", ["reason": "displayLinkStalled"])
            if let link = self.displayLink { CVDisplayLinkStop(link) }
            self.displayLink = nil
            self.startTimerFallback()
        }
    }

    /// Coalesce DisplayLink callbacks so main only ever has one pending tick.
    private func scheduleTick() {
        let already = tickPending.withLock { pending -> Bool in
            if pending { return true }
            pending = true
            return false
        }
        if already { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickPending.withLock { $0 = false }
            self.tick()
        }
    }

    private func startTimerFallback() {
        guard timerFallback == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        t.setEventHandler { [weak self] in self?.tick() }
        timerFallback = t
        t.resume()
    }

    // MARK: - Tick

    private func tick() {
        guard animating else { return }
        if capsuleFrozen {
            return
        }
        ticksSinceAnimationStart += 1
        let tickStartUs = Timing.enabled ? Timing.nowUs() : 0
        if awaitingFirstFrame {
            // The first visible frame was committed during the previous run-loop pass.
            awaitingFirstFrame = false
            Timing.event("hud.frame")
        }

        let mono = Timing.nowMs()
        var wallDt = Tunables.simDt
        if let prev = lastAnimMonoMs {
            let elapsed = Double(mono &- prev) / 1000.0
            if elapsed > 0, elapsed < 0.25 {
                wallDt = elapsed
            }
        }
        lastAnimMonoMs = mono

        if presentation == .recording {
            enterProgress = min(1, enterProgress + wallDt / (Tunables.enterMs / 1000))
            let e = easeOut(enterProgress)
            opacity = e
            scale = reduceMotion ? 1 : 0.90 + 0.10 * e

            let sample = audio.consumePeak()
            if sample.freshness == .fresh, oldestUnshownPacketMs == 0 {
                oldestUnshownPacketMs = sample.oldestPacketMonoMs
            }
            let unavailable = sample.freshness == .unavailable
            sim.levelsUnavailable = unavailable
            let pastGrace = mono &- recordingEnteredMs >= Self.levelsGraceMs
            detail = unavailable && pastGrace ? "Audio levels unavailable" : ""
            reportLevels(unavailable: unavailable, pastGrace: pastGrace)
            let snapSim = sim.advance(
                toMonoMs: mono,
                peak: unavailable ? 0 : sample.peak,
                peakFresh: sample.freshness == .fresh
            )
            // Tick the sim at display rate (onsets need 120 Hz against 100 Hz audio frames);
            // publish the view at ~60 Hz.
            if mono &- lastPublishMonoMs >= 15 {
                lastPublishMonoMs = mono
                publish(from: snapSim)
            }
        } else if presentation == .transcribing {
            if collapseProgress < 1 {
                collapseProgress = min(1, collapseProgress + wallDt / (Tunables.collapseMs(for: mascot) / 1000)) // polish-shared: WS1 per-mascot collapse duration
                let c = easeOut(collapseProgress)
                sim.setBagVisible(1 - c)
                opacity = 1
                scale = reduceMotion ? 1 : 1 - 0.35 * c
                let snapSim = sim.advance(toMonoMs: mono, peak: 0)
                publish(from: snapSim)
            }
            if collapseProgress >= 1 {
                publishCapsuleOnly()
                capsuleFrozen = true
                stopAnimation()
                // Keep presentation so idle can still hide; animating false until next state.
                animating = false
            }
        }
        if Timing.enabled {
            Timing.event("hud.tick", ["us": String(Timing.nowUs() - tickStartUs)])
        }
    }

    private func reportLevels(unavailable: Bool, pastGrace: Bool) {
        if unavailable, pastGrace, !levelsReportedUnavailable {
            levelsReportedUnavailable = true
            health?.noteAudioLevels(available: false)
        } else if !unavailable, levelsReportedUnavailable {
            levelsReportedUnavailable = false
            health?.noteAudioLevels(available: true)
        }
    }

    private func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    private func publish(from snap: SimSnapshot) {
        let frame = PopcornFrame(
            opacity: opacity,
            scale: scale,
            scene: PopcornRenderer.SceneInput(
                snapshot: snap, label: label, detail: detail, presentation: presentation,
                reduceMotion: reduceMotion, mascot: mascot
            )
        )
        let kernelsMoving = presentation == .recording || collapseProgress < 1
        if kernelsMoving || frame != lastPublish {
            setRoot(frame)
        }
    }

    private func publishCapsuleOnly() {
        let frame = PopcornFrame(
            opacity: 1, scale: reduceMotion ? 1 : 0.65,
            scene: .still(label: label, presentation: .transcribing, reduceMotion: reduceMotion, mascot: mascot)
        )
        if frame != lastPublish {
            setRoot(frame)
        }
    }

    private func setRoot(_ frame: PopcornFrame) {
        lastPublish = frame
        guard Timing.enabled else {
            hosting?.rootView = PopcornView(frame: frame)
            return
        }
        let start = Timing.nowUs()
        hosting?.rootView = PopcornView(frame: frame)
        let now = Timing.nowUs()
        Timing.event("hud.publish", ["us": String(now - start)])
        if awaitingFirstVisible, frame.opacity > 0, presentation == .recording {
            awaitingFirstVisible = false
            awaitingFirstFrame = true
            Timing.event("hud.visible", ["opacity": String(format: "%.2f", frame.opacity)])
        }
        if oldestUnshownPacketMs > 0, presentation == .recording {
            Timing.event("audio.react", ["ms": String(format: "%.1f", Double(now) / 1000 - Double(oldestUnshownPacketMs))])
            oldestUnshownPacketMs = 0
        }
    }
}
