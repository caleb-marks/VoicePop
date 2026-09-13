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
    @StateObject private var engine = AppearancePreviewEngine()

    var body: some View {
        Form {
            Section("Mascot") {
                Picker("Mascot", selection: Binding(
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
                .accessibilityLabel("Mascot")
            }

            Section("Preview") {
                Picker("Preview input", selection: $intensity) {
                    Text("Quiet").tag(SyntheticIntensity.quiet)
                    Text("Normal").tag(SyntheticIntensity.normal)
                    Text("Energetic").tag(SyntheticIntensity.energetic)
                }
                .pickerStyle(.segmented)
                .onChange(of: intensity) { newValue in engine.setIntensity(newValue) }

                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !engine.running)) { context in
                    Canvas { ctx, _ in
                        let scene = engine.advance(to: context.date, mascot: store.prefs.mascot)
                        PopcornRenderer.drawScene(ctx: &ctx, scene: scene)
                    }
                    .frame(width: Tunables.cardW * 0.62, height: Tunables.cardH * 0.62)
                    .scaleEffect(0.62, anchor: .center)
                    .frame(width: Tunables.cardW * 0.62, height: Tunables.cardH * 0.62)
                }
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
        }
        .onDisappear { engine.setTabVisible(false) }
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
/// visibility (SwiftUI appear/disappear) and window visibility (occlusion/miniaturize/app-hide).
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

    init() {
        sim.reduceMotion = reduceMotion
        reduceMotionObserver = NotificationCenter.default.addObserver(
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
        if let reduceMotionObserver { NotificationCenter.default.removeObserver(reduceMotionObserver) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
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
        running = tabVisible && windowVisible
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
