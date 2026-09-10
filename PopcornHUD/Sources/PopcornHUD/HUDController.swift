import AppKit
import CoreFoundation
import os
import SwiftUI
import PopcornArt
import PopcornCore

final class HUDController {
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
    private var drawScratch: [PopcornRenderer.KernelDraw] = []
    private var lastPublishMonoMs: UInt64 = 0
    private var mascot: Mascot = .popcorn

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
        stopAnimation()
        audio.stop()
        panel?.orderOut(nil)
    }

    private func transcriptReady() {
        guard presentation == .transcribing else { return }
        Timing.log("transcript ready")
        beginHide()
    }

    func start(watcher: StateWatcher) {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.positionPanel()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.positionPanel()
        }
        NotificationCenter.default.addObserver(
            forName: .voicePopMascotDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let next = note.object as? Mascot {
                self.mascot = next
            } else {
                self.mascot = StylePrefsCache.current().mascot
            }
            if self.presentation != .hidden, let last = self.lastPublish {
                var updated = last
                updated.mascot = self.mascot
                self.lastPublish = updated
                self.hosting?.rootView = PopcornView(frame: updated)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.sim.reduceMotion = self.reduceMotion
            if self.reduceMotion { self.scale = 1 }
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let ctrl = Unmanaged<HUDController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { ctrl.transcriptReady() }
            },
            VoicePopSignal.transcriptReady as CFString,
            nil,
            .deliverImmediately
        )

        buildPanel()
        watcher.addListener { [weak self] state in
            self?.handleState(state)
        }
        fputs("VoicePop started\n", stderr)
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
            opacity: 0, scale: 0.9, bagVisible: 1, heat: 0, mood: 0, kick: 0, bobPhase: 0,
            label: "", detail: "", presentation: .hidden, reduceMotion: reduceMotion, kernels: []
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
        sim.reset()
        sim.allowSpawn = true
        sim.reduceMotion = reduceMotion
        sim.setBagVisible(1)
        audio.start()
        attachHost()
        positionPanel()
        panel?.orderFrontRegardless()
        NSAccessibility.post(element: panel as Any, notification: .announcementRequested, userInfo: [
            .announcement: label as NSString,
            .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
        startAnimation()
        Timing.log("enter recording")
    }

    private func beginTranscribing() {
        guard presentation == .recording || presentation == .transcribing else { return }
        presentation = .transcribing
        label = "Transcribing…"
        detail = ""
        sim.allowSpawn = false
        audio.stop()
        collapseProgress = 0
        lastAnimMonoMs = nil
        capsuleFrozen = false
        NSAccessibility.post(element: panel as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Transcribing" as NSString,
            .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
        startAnimation()
        Timing.log("transcribing")
    }

    private func beginHide() {
        audio.stop()
        sim.allowSpawn = false
        capsuleFrozen = false
        if presentation == .hidden {
            stopAnimation()
            return
        }
        // Neutral dismiss — no success
        presentation = .hidden
        opacity = 0
        scale = 0.90
        sim.reset()
        panel?.orderOut(nil)
        stopAnimation()
        detachHost()
        Timing.log("hidden")
    }

    private func startAnimation() {
        guard !animating else { return }
        animating = true
        tickPending.withLock { $0 = false }
        if !startDisplayLink() {
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

    private func startDisplayLink() -> Bool {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            return false
        }
        displayLink = link
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let ctrl = Unmanaged<HUDController>.fromOpaque(userInfo!).takeUnretainedValue()
            ctrl.scheduleTick()
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        return true
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
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        t.setEventHandler { [weak self] in self?.tick() }
        timerFallback = t
        t.resume()
    }

    private func tick() {
        guard animating else { return }
        if capsuleFrozen {
            return
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
            sim.levelsUnavailable = sample.freshness == .unavailable
            if sim.levelsUnavailable {
                detail = "Audio levels unavailable"
            } else {
                detail = ""
            }
            let usePeak: Float = sample.freshness == .unavailable ? 0 : sample.peak
            let snapSim = sim.advance(
                toMonoMs: mono,
                peak: usePeak,
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
                collapseProgress = min(1, collapseProgress + wallDt / (Tunables.collapseMs / 1000))
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
    }

    private func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    private func publish(from snap: SimSnapshot) {
        drawScratch.removeAll(keepingCapacity: true)
        if drawScratch.capacity < Tunables.maxKernels {
            drawScratch.reserveCapacity(Tunables.maxKernels)
        }
        for k in snap.kernels {
            drawScratch.append(PopcornRenderer.KernelDraw(
                front: k.front, settled: k.settled,
                x: CGFloat(k.x), y: CGFloat(k.y), scale: CGFloat(k.scale),
                rot: CGFloat(k.rot), shape: k.shape, butter: CGFloat(k.butter), alpha: k.alpha
            ))
        }
        let frame = PopcornFrame(
            opacity: opacity,
            scale: scale,
            bagVisible: snap.bagVisible,
            heat: snap.heat,
            mood: snap.mood,
            kick: snap.kick,
            bobPhase: snap.phase,
            label: label,
            detail: detail,
            presentation: presentation,
            reduceMotion: reduceMotion,
            kernels: drawScratch,
            mascot: mascot
        )
        let kernelsMoving = presentation == .recording || collapseProgress < 1
        if kernelsMoving {
            lastPublish = frame
            hosting?.rootView = PopcornView(frame: frame)
        } else if frame != lastPublish {
            lastPublish = frame
            hosting?.rootView = PopcornView(frame: frame)
        }
    }

    private func publishCapsuleOnly() {
        let frame = PopcornFrame(
            opacity: 1, scale: reduceMotion ? 1 : 0.65, bagVisible: 0, heat: 0, mood: 0, kick: 0, bobPhase: 0,
            label: label, detail: "", presentation: .transcribing, reduceMotion: reduceMotion, kernels: [],
            mascot: mascot
        )
        if frame != lastPublish {
            lastPublish = frame
            hosting?.rootView = PopcornView(frame: frame)
        }
    }
}
