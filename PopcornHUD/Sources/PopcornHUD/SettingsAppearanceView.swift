import AppKit
import SwiftUI
import PopcornArt
import PopcornCore

/// Appearance tab (§3): mascot choice plus a live preview using the *production* renderer and
/// motion (`PopcornSim` + `SyntheticSpeech` + `PopcornRenderer.SceneInput`/`drawScene`) - never
/// the microphone, and never the same `PopcornSim` instance the HUD uses. Preview work pauses
/// when the tab isn't visible, the window is hidden/miniaturized/occluded, or Reduce Motion is on.
struct SettingsAppearanceView: View {
    @ObservedObject var store: SettingsStore
    @State private var intensity: SyntheticIntensity = .normal
    @State private var visible = true
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
                .accessibilityHidden(true)
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
            engine.resume()
        }
        .onDisappear { engine.pause() }
    }
}

/// Owns a standalone `PopcornSim` + `SyntheticSpeech` pair, isolated from the HUD's simulation.
/// `running` gates the `TimelineView` so no work happens while paused.
final class AppearancePreviewEngine: ObservableObject {
    @Published private(set) var running = false
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private let sim = PopcornSim(seed: 99)
    private var speech = SyntheticSpeech(intensity: .normal, seed: 99)
    private var startMono: UInt64?
    private var observer: NSObjectProtocol?

    init() {
        sim.reduceMotion = reduceMotion
        observer = NotificationCenter.default.addObserver(
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
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func setIntensity(_ intensity: SyntheticIntensity) {
        speech = SyntheticSpeech(intensity: intensity, seed: 99)
        sim.reset(seed: 99)
        startMono = nil
    }

    func resume() { running = true }
    func pause() { running = false }

    func advance(to date: Date, mascot: Mascot) -> PopcornRenderer.SceneInput {
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
