import AppKit
import SwiftUI
import PopcornArt
import PopcornCore

/// Appearance tab (§3): mascot choice plus a live preview using the *production* renderer and
/// motion (`PopcornSim` + `SyntheticSpeech` + `PopcornRenderer.SceneInput`/`drawScene`) - never
/// the microphone, and never the same `PopcornSim` instance the HUD uses. Preview work pauses
/// when the tab isn't visible (`onAppear`/`onDisappear`), or the window is closed, miniaturized,
/// occluded, or the app is hidden (`WindowAccessor` + `NSWindow`/`NSApplication` notifications) -
/// `onAppear`/`onDisappear` alone do not fire reliably for window-level visibility changes.
struct SettingsAppearanceView: View {
    @ObservedObject var store: SettingsStore
    @State private var intensity: SyntheticIntensity = .normal
    /// Preview is the production 260x420 card scaled down; the top `previewTopCrop` card px are
    /// always empty (see the Canvas comment) and are cropped so the tab isn't mostly blank.
    private static let previewScale: CGFloat = 0.62
    private static let previewTopCrop: CGFloat = 70
    @StateObject private var engine: AppearancePreviewEngine

    /// `fixtureEngine`, when provided (harness-only), is used as-is instead of a fresh engine -
    /// e.g. one already `preroll`ed a couple of seconds so a snapshot shows motion mid-animation
    /// instead of frame zero.
    init(store: SettingsStore, fixtureEngine: AppearancePreviewEngine? = nil) {
        self.store = store
        _engine = StateObject(wrappedValue: fixtureEngine ?? AppearancePreviewEngine())
    }

    var body: some View {
        Form {
            Section("Mascot") {
                // The section header already says "Mascot"; a second visible label reads as a
                // duplicate. The accessibility label below keeps the name for VoiceOver.
                Picker("", selection: Binding(
                    get: { store.prefs.mascot },
                    set: { newValue in
                        store.prefs.mascot = newValue
                        store.save()
                        NotificationCenter.default.post(name: .voicePopMascotDidChange, object: newValue)
                    }
                )) {
                    Text("Popcorn bucket").tag(Mascot.popcorn)
                    Text("Nandor the beagle").tag(Mascot.beagle)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel("Mascot")
                if let error = store.saveError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { store.save() }
                    }
                }
            }

            Section("Preview") {
                Picker("Preview input", selection: $intensity) {
                    Text("Quiet").tag(SyntheticIntensity.quiet)
                    Text("Normal").tag(SyntheticIntensity.normal)
                    Text("Energetic").tag(SyntheticIntensity.energetic)
                }
                .pickerStyle(.segmented)
                .onChange(of: intensity) { newValue in engine.setIntensity(newValue) }

                HStack {
                    Spacer(minLength: 0)
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !engine.running)) { context in
                        // `drawScene` draws in full 260x420 card coordinates - the Canvas must be
                        // sized to match that before scaling down, or its content clips against a
                        // too-small canvas before the scale even applies (H-2).
                        Canvas { ctx, _ in
                            let scene = engine.advance(to: context.date, mascot: store.prefs.mascot)
                            PopcornRenderer.drawScene(ctx: &ctx, scene: scene)
                        }
                        .frame(width: Tunables.cardW, height: Tunables.cardH)
                        // Anchor at the bottom and crop the card's empty headroom: the highest
                        // kernel apex is ~85 card px from the top (launch speed vs gravity), so
                        // trimming `previewTopCrop` removes only transparent space above the
                        // pile - the canvas itself still lays out at full size.
                        .scaleEffect(Self.previewScale, anchor: .bottom)
                        .frame(
                            width: Tunables.cardW * Self.previewScale,
                            height: (Tunables.cardH - Self.previewTopCrop) * Self.previewScale,
                            alignment: .bottom
                        )
                        .clipped()
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .background(WindowAccessor { window in engine.attach(window: window) })
                // Not just `.accessibilityHidden` - a short textual description survives even
                // where hiding it entirely would leave VoiceOver with nothing to say about the
                // chosen mascot.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(store.prefs.mascot == .popcorn ? "Popcorn bucket preview, animating" : "Nandor the beagle preview, animating")
                if engine.reduceMotion {
                    Text("Reduce Motion is on: the preview shows recording feedback without decorative motion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("This preview never uses the microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            engine.setIntensity(intensity)
            engine.setTabVisible(true)
            engine.setHUDActive(store.status.daemon.isHot || store.status.daemon.isTranscribing)
        }
        .onDisappear { engine.setTabVisible(false) }
        // `store.status` comes from SettingsStore's single, window-lifetime health listener
        // (M-7) rather than this view adding its own on every appearance.
        .onChange(of: store.status) { newStatus in
            engine.setHUDActive(newStatus.daemon.isHot || newStatus.daemon.isTranscribing)
        }
    }
}

/// Reports the hosting `NSWindow` back to SwiftUI once it's attached, so a plain SwiftUI view can
/// observe window-level notifications (occlusion, miniaturize, close) that have no SwiftUI
/// equivalent.
private struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { callback(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { callback(nsView.window) }
    }
}

/// Owns a standalone `PopcornSim` + `SyntheticSpeech` pair, isolated from the HUD's simulation.
/// `running` gates the `TimelineView` so no work happens while paused; it is the AND of tab
/// visibility (SwiftUI appear/disappear), window visibility (occlusion/miniaturize/app-hide), and
/// the HUD being idle (a live dictation's HUD must never compete with this preview on main).
final class AppearancePreviewEngine: ObservableObject {
    @Published private(set) var running = false
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Incremented on every `advance(to:mascot:)` call. Read by the `VOICEPOP_UI_SNAPSHOT`
    /// harness to verify the TimelineView actually stops driving the sim when hidden - a
    /// `running` flag that nothing ever reads for real would not catch a wiring mistake.
    private(set) var advanceCount = 0

    private let sim = PopcornSim(seed: 99)
    private var speech = SyntheticSpeech(intensity: .normal, seed: 99)
    private var startMono: UInt64?
    private var reduceMotionObserver: NSObjectProtocol?
    private weak var window: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var tabVisible = false
    private var windowVisible = true
    private var hudActive = false

    init() {
        sim.reduceMotion = reduceMotion
        // Posted on NSWorkspace's own notification center, not NotificationCenter.default (L-2) -
        // using the wrong one meant toggling Reduce Motion while Settings was open silently did
        // nothing here, even though the HUD (which uses the right center) picked it up.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.sim.reduceMotion = self.reduceMotion
            self.objectWillChange.send()
        }
    }

    deinit {
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Harness-only: advances the sim/speech pair by synthetic ticks without a live TimelineView,
    /// so a snapshot can show the preview mid-animation instead of its resting first frame.
    func preroll(seconds: Double, mascot: Mascot) {
        let stepMs: UInt64 = 16
        var mono: UInt64 = 1_000_000
        let steps = Int((seconds * 1000) / Double(stepMs))
        for _ in 0..<steps {
            _ = advance(to: Date(timeIntervalSinceReferenceDate: Double(mono) / 1000), mascot: mascot)
            mono += stepMs
        }
    }

    func setIntensity(_ intensity: SyntheticIntensity) {
        speech = SyntheticSpeech(intensity: intensity, seed: 99)
        sim.reset(seed: 99)
        startMono = nil
    }

    func setTabVisible(_ visible: Bool) {
        tabVisible = visible
        recomputeRunning()
    }

    /// True while a real dictation is recording/streaming/transcribing - the HUD is rendering on
    /// main then, and the preview (same process, same main thread) must yield to it rather than
    /// run two Canvas/sim workloads at once.
    func setHUDActive(_ active: Bool) {
        hudActive = active
        recomputeRunning()
    }

    /// Attaches window-level observers exactly once per window (the `WindowAccessor` reports the
    /// window on every SwiftUI update, not just once).
    func attach(window: NSWindow?) {
        guard window !== self.window else { return }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        self.window = window
        guard let window else { return }
        let center = NotificationCenter.default
        let recompute: (Notification) -> Void = { [weak self] _ in self?.recomputeRunning() }
        windowObservers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: recompute),
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: recompute),
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main, using: recompute),
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main, using: recompute),
            center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main, using: recompute),
            center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main, using: recompute),
        ]
        recomputeRunning()
    }

    private func recomputeRunning() {
        if let window {
            windowVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden
        }
        running = tabVisible && windowVisible && !hudActive
    }

    func advance(to date: Date, mascot: Mascot) -> PopcornRenderer.SceneInput {
        advanceCount += 1
        let mono = UInt64(date.timeIntervalSinceReferenceDate * 1000)
        if startMono == nil { startMono = mono }
        let (peak, fresh) = speech.sample(atMonoMs: mono)
        let snapshot = sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh)
        return PopcornRenderer.SceneInput(
            snapshot: snapshot,
            label: "Preview",
            presentation: .recording,
            reduceMotion: reduceMotion,
            mascot: mascot
        )
    }
}
