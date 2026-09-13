import AppKit
import PopcornCore
import SwiftUI

/// Drives the setup checklist: probes and installs off the main thread, gathers functional
/// evidence from daemon state and the practice field, and persists that evidence.
final class SetupChecklistModel: ObservableObject {
    @Published private(set) var list: SetupChecklist
    @Published var practiceText = "" {
        didSet { observePractice() }
    }
    @Published private(set) var servicesRunning = false

    private let store: SetupEvidenceStore
    private var working = false
    private var onServicesReady: (() -> Void)?
    /// Main thread only.
    private var engineOrModelChanged = false
    private var lastTranscriptAt: Date?
    /// Set once services start; downloads and installs report here so the menu stays truthful.
    weak var health: DictationHealthMonitor?

    init(store: SetupEvidenceStore = SetupEvidenceStore()) {
        self.store = store
        list = SetupChecklist(evidence: store.load())
    }

    // MARK: Lifecycle

    func begin(install: Bool, onServicesReady: (() -> Void)?) {
        if let onServicesReady { self.onServicesReady = onServicesReady }
        if install { runInstall() } else { probe() }
    }

    func servicesStarted() {
        servicesRunning = true
    }

    // polish-shared (WS2): harness-only hook so VOICEPOP_UI_SNAPSHOT can render a fixture
    // checklist state without invoking real probes/installs. Does not change any other behavior.
    func loadFixtureForSnapshot(_ list: SetupChecklist) {
        self.list = list
    }

    /// Re-check engine and model without installing anything.
    func probe() {
        guard !working else { return }
        working = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let engine = SetupAssistant.engineReady()
            let model = engine && SetupAssistant.modelInstalled()
            let config = SetupAssistant.configPresent()
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                self.list.engine = engine && config
                    ? .done("Voxtype is installed.")
                    : .needsAction(engine ? "Voxtype needs its dictation settings." : "Voxtype isn’t installed yet.")
                self.list.model = !engine
                    ? .pending
                    : model ? .done("The Parakeet speech model is on this Mac.") : .needsAction("The speech model isn’t downloaded yet (about 2.4 GB, one time).")
                self.announceProgress()
                self.startServicesIfReady()
            }
        }
    }

    /// Install engine, write config, and download the model, reporting progress per step.
    func runInstall() {
        guard !working else { return }
        working = true
        list.engine = .working(message: "Checking the speech engine…", fraction: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let hadEngine = SetupAssistant.engineReady()
                try SetupAssistant.installEngine { message, fraction in
                    DispatchQueue.main.async { self.list.engine = .working(message: message, fraction: fraction) }
                }
                try SetupAssistant.writeConfigIfMissing()
                DispatchQueue.main.async {
                    if !hadEngine {
                        // A new Voxtype install has no macOS permissions yet.
                        self.list.engineReinstalled()
                        self.store.save(self.list.evidence)
                    }
                    self.list.engine = .done(hadEngine ? "Voxtype is installed." : "Installed Voxtype.")
                    self.list.model = .working(message: "Checking the speech model…", fraction: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.working = false
                    self.list.engine = .failed(error.localizedDescription)
                    self.announce("Speech engine setup failed")
                }
                return
            }
            do {
                if !SetupAssistant.modelInstalled() {
                    DispatchQueue.main.async { self.engineOrModelChanged = true }
                    try SetupAssistant.downloadModel { message, fraction in
                        DispatchQueue.main.async {
                            self.list.model = .working(message: message, fraction: fraction)
                            self.health?.noteModelDownload(.init(model: SetupAssistant.modelName, fraction: fraction))
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.working = false
                    self.list.model = .done("The Parakeet speech model is on this Mac.")
                    self.health?.noteModelDownload(nil)
                    self.health?.refresh()
                    self.announceProgress()
                    self.startServicesIfReady()
                }
            } catch {
                DispatchQueue.main.async {
                    self.working = false
                    self.health?.noteModelDownload(nil)
                    self.list.model = .failed(error.localizedDescription)
                    self.announce("Speech model download failed")
                }
            }
        }
    }

    private func startServicesIfReady() {
        guard list.servicesReady else { return }
        if let start = onServicesReady {
            onServicesReady = nil
            start()
        }
        if engineOrModelChanged {
            engineOrModelChanged = false
            // A daemon that was already running still has the old model loaded.
            DispatchQueue.global(qos: .utility).async {
                if VoxtypeDaemon.isLive() { DispatchQueue.main.async { EngineControl.restart() } }
            }
        }
    }

    // MARK: Evidence

    func observe(daemon: DaemonState) {
        let before = list
        list.observe(daemon: daemon)
        commitEvidence(before)
    }

    /// Failure evidence from health, accepted at any time: it can only clear earlier success.
    func invalidate(with status: DictationStatus) {
        let failure = status.facts.lastFailure.flatMap(DictationFailure.init(rawValue:))
        guard list.invalidateEvidence(issue: status.issue, failure: failure) else { return }
        store.save(list.evidence)
    }

    func observeTranscript() {
        lastTranscriptAt = Date()
        let before = list
        list.observeTranscript()
        commitEvidence(before)
    }

    private func observePractice() {
        let before = list
        list.observePracticeText(practiceText, secondsSinceTranscript: lastTranscriptAt.map { Date().timeIntervalSince($0) })
        commitEvidence(before)
    }

    private func commitEvidence(_ before: SetupChecklist) {
        guard list.evidence != before.evidence else { return }
        store.save(list.evidence)
        announceProgress(previous: before)
    }

    private func announceProgress(previous: SetupChecklist? = nil) {
        for step in SetupChecklist.Step.allCases {
            let now = list.state(of: step)
            if now.isDone, previous.map({ !$0.state(of: step).isDone }) ?? false {
                announce("\(SetupChecklistView.title(for: step)) done")
            }
        }
        if list.isComplete, previous.map({ !$0.isComplete }) ?? false {
            announce("VoicePop is ready")
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text as NSString,
            .priority: NSAccessibilityPriorityLevel.high.rawValue as NSNumber,
        ])
    }
}

/// One checklist window, reused and brought forward.
final class SetupChecklistWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupChecklistWindowController()

    let model = SetupChecklistModel()
    private var window: NSWindow?
    private weak var health: DictationHealthMonitor?
    private var listening = false
    private var lastMenuRecordRequest: Date?

    /// Called once services exist, so daemon state can count as FN/permission evidence.
    func attach(health: DictationHealthMonitor) {
        self.health = health
        model.health = health
        model.servicesStarted()
        guard !listening else { return }
        listening = true
        health.addListener { [weak self] status in
            guard let self else { return }
            self.model.invalidate(with: status)
            // Success evidence counts only while the checklist is on screen, where the user was
            // asked to hold FN and practice.
            guard self.window?.isVisible == true else { return }
            // A recording started from the menu proves nothing about the FN key.
            if status.daemon.isHot, let menu = self.lastMenuRecordRequest, Date().timeIntervalSince(menu) < 3 {
                return
            }
            self.model.observe(daemon: status.daemon)
        }
        NotificationCenter.default.addObserver(forName: .voicePopRecordRequested, object: nil, queue: .main) { [weak self] _ in
            self?.lastMenuRecordRequest = Date()
        }
        health.addTranscriptReadyListener { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.model.observeTranscript()
        }
    }

    func present(install: Bool, onServicesReady: (() -> Void)?) {
        if window == nil { build() }
        model.begin(install: install, onServicesReady: onServicesReady)
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let host = NSHostingController(rootView: SetupChecklistView(model: model, close: { [weak self] in
            self?.window?.performClose(nil)
        }))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Set Up VoicePop"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(host.view.fittingSize)
        self.window = window
    }
}

struct SetupChecklistView: View {
    @ObservedObject var model: SetupChecklistModel
    var close: () -> Void

    static func title(for step: SetupChecklist.Step) -> String {
        switch step {
        case .engine: return "Speech engine"
        case .model: return "Speech model"
        case .permissions: return "Permissions for Voxtype"
        case .fnKey: return "FN key"
        case .practice: return "Practice dictation"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up VoicePop")
                    .font(.title2.weight(.semibold))
                Text("\(model.list.completedCount) of \(SetupChecklist.Step.allCases.count) steps done · Everything runs on this Mac.")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            ForEach(Array(SetupChecklist.Step.allCases.enumerated()), id: \.element) { index, step in
                StepRow(number: index + 1, title: Self.title(for: step), state: model.list.state(of: step)) {
                    actions(for: step)
                }
                if index < SetupChecklist.Step.allCases.count - 1 { Divider() }
            }

            HStack {
                if model.list.isComplete {
                    Label("Ready. Hold FN in any app to dictate.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else if !model.servicesRunning {
                    Text("Dictation starts when the engine and model are ready. Click VoicePop in the Dock to return here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                } else {
                    Text("You can close this and come back from Settings › General › Check Setup…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.list.isComplete ? "Done" : "Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder
    private func actions(for step: SetupChecklist.Step) -> some View {
        switch step {
        case .engine:
            switch model.list.engine {
            case .failed, .needsAction: Button("Install") { model.runInstall() }
            default: EmptyView()
            }
        case .model:
            switch model.list.model {
            case .failed: Button("Try Again") { model.runInstall() }
            case .needsAction: Button("Download") { model.runInstall() }
            default: EmptyView()
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn on **Voxtype** (not VoicePop) in each list. macOS asks for Microphone the first time you record.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                HStack {
                    Button("Accessibility…") { openSettings("com.apple.preference.security?Privacy_Accessibility") }
                    Button("Input Monitoring…") { openSettings("com.apple.preference.security?Privacy_ListenEvent") }
                    Button("Microphone…") { openSettings("com.apple.preference.security?Privacy_Microphone") }
                }
                Text("VoicePop can’t read these switches directly. This step completes when the practice dictation types text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
        case .fnKey:
            VStack(alignment: .leading, spacing: 6) {
                Text("In Keyboard settings, set **Press 🌐 key to** Do Nothing so macOS doesn’t take the key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                Button("Open Keyboard Settings…") { openSettings("com.apple.Keyboard-Settings.extension") }
            }
        case .practice:
            if model.list.servicesReady {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Click here, hold FN, say “testing one two three”, release", text: $model.practiceText, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Practice dictation field")
                    if !model.servicesRunning {
                        Text("Dictation is starting…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func openSettings(_ suffix: String) {
        if let url = URL(string: "x-apple.systempreferences:" + suffix) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct StepRow<Actions: View>: View {
    var number: Int
    var title: String
    var state: SetupChecklist.StepState
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                detail
                actions()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(statusWord)")
    }

    private var statusWord: String {
        switch state {
        case .pending: return "waiting"
        case .working: return "in progress"
        case .needsAction: return "needs your action"
        case .failed: return "failed"
        case .done: return "done"
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .working: ProgressView().controlSize(.small)
        case .needsAction: Image(systemName: "circle.dashed").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder private var detail: some View {
        switch state {
        case .pending:
            Text("Waiting for the steps above.").foregroundStyle(.secondary).wrapsLines()
        case .working(let message, let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).foregroundStyle(.secondary).wrapsLines()
                if let fraction {
                    ProgressView(value: fraction).accessibilityLabel(message)
                } else {
                    ProgressView().progressViewStyle(.linear).accessibilityLabel(message)
                }
            }
        case .needsAction(let message):
            Text(message).wrapsLines()
        case .failed(let message):
            Text(message).foregroundStyle(.red).wrapsLines().textSelection(.enabled)
        case .done(let message):
            Text(message).foregroundStyle(.secondary).wrapsLines()
        }
    }
}

private extension View {
    func wrapsLines() -> some View { fixedSize(horizontal: false, vertical: true) }
}
