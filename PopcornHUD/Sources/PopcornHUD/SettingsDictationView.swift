import SwiftUI
import PopcornCore

/// Dictation tab (§3): model catalog with descriptions/installed state/download progress,
/// global + per-app writing style, and the optional local-polishing toggle. No engine-tuning
/// sliders. The download/switch path runs through `ModelInstallRunning` so it can be swapped for
/// a fixture-driven runner in tests instead of ever invoking the live engine.
struct SettingsDictationView: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var models: ModelListViewModel
    @State private var newAppName = ""

    init(store: SettingsStore, fixtureModels: ModelListViewModel? = nil) {
        self.store = store
        _models = StateObject(wrappedValue: fixtureModels ?? ModelListViewModel())
    }

    var body: some View {
        Form {
            Section("Speech model") {
                ForEach(VoxtypeModel.catalog, id: \.id) { choice in
                    modelRow(choice)
                }
                if let error = models.failure {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { models.retry() }
                    }
                }
            }

            Section("Writing style") {
                Picker("Global style", selection: Binding(
                    get: { store.prefs.global },
                    set: { store.prefs.global = $0; store.save() }
                )) {
                    Text("Automatic").tag(Style.auto)
                    Text("Casual").tag(Style.casual)
                    Text("Formal").tag(Style.formal)
                }
                ForEach(Array(store.prefs.perApp.keys.sorted()), id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.prefs.perApp[app] ?? .auto },
                            set: { store.prefs.perApp[app] = $0; store.save() }
                        )) {
                            // A hand-set .auto per-app override (or one this list itself no
                            // longer manages a case for) otherwise shows no selection at all (N-4).
                            Text("Automatic").tag(Style.auto)
                            Text("Casual").tag(Style.casual)
                            Text("Formal").tag(Style.formal)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Button(role: .destructive) {
                            store.prefs.perApp.removeValue(forKey: app)
                            store.save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Remove override for \(app)")
                    }
                }
                HStack {
                    TextField("App name (as shown in menu)", text: $newAppName)
                    Button("Add") {
                        let trimmed = newAppName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        store.prefs.perApp[trimmed] = .casual
                        store.save()
                        newAppName = ""
                    }
                    .disabled(newAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Local AI polishing") {
                Toggle("Polish Formal text with local AI (Ollama)", isOn: Binding(
                    get: { store.prefs.llm.enabled },
                    set: { store.prefs.llm.enabled = $0; store.save() }
                ))
                Text("Optional. Runs entirely on this Mac over loopback - no text ever leaves the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if !models.skipAutoRefresh { models.refresh() } }
    }

    @ViewBuilder
    private func modelRow(_ choice: VoxtypeModel.Choice) -> some View {
        let isCurrent = VoxtypeModel.matches(models.current, catalogID: choice.id)
        let isInstalled = isCurrent || models.installed.contains { VoxtypeModel.matches($0, catalogID: choice.id) }
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(choice.title).fontWeight(isCurrent ? .semibold : .regular)
                    if isCurrent { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if isInstalled { Text("Installed").font(.caption).foregroundStyle(.secondary) }
                }
                Text(choice.summary).font(.caption).foregroundStyle(.secondary)
                Text(String(format: "~%.1f GB", choice.approxSizeGB)).font(.caption2).foregroundStyle(.tertiary)
                if models.downloadingID == choice.id {
                    // An indeterminate ProgressView() while fraction is unknown, instead of a
                    // determinate bar frozen at 0% (N-4).
                    if let fraction = models.downloadFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(models.downloadMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(isCurrent ? "Selected" : (isInstalled ? "Use" : "Download & Use")) {
                models.select(choice.id)
            }
            .disabled(isCurrent || models.downloadingID != nil)
        }
        .padding(.vertical, 2)
    }
}

@MainActor
final class ModelListViewModel: ObservableObject {
    @Published var installed: Set<String> = []
    @Published var current: String?
    @Published var downloadingID: String?
    @Published var downloadFraction: Double?
    @Published var downloadMessage = ""
    @Published var failure: String?

    var runner: ModelInstallRunning = LiveModelInstallRunner()
    /// Harness-only: true when this instance was pre-seeded with fixture state, so `onAppear`
    /// doesn't immediately overwrite it by probing the live engine.
    var skipAutoRefresh = false
    /// Read lazily (like `SettingsStore.attachHealthIfNeeded`, L-1) rather than captured at init,
    /// so a Settings window built before `AppDelegate` sets `health` still reports downloads once
    /// it's available. `INTERFACES.md` #6: Settings downloads must report to
    /// `health.noteModelDownload` (M-6) so the menu headline shows "Downloading speech model… N%"
    /// instead of staying "Ready" during a Settings-initiated download.
    var health: DictationHealthMonitor? { SettingsWindowController.shared.health }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let installed = VoxtypeModel.installedNames()
            let current = VoxtypeModel.currentModel()
            DispatchQueue.main.async {
                self?.installed = installed
                self?.current = current
            }
        }
    }

    func retry() {
        guard let id = lastAttempted else { return }
        select(id)
    }

    private var lastAttempted: String?

    func select(_ catalogID: String) {
        guard downloadingID == nil, !VoxtypeModel.matches(current, catalogID: catalogID) else { return }
        // Prefer the engine's own installed spelling (e.g. a "-prepacked" variant) so switching
        // to an already-installed model never re-triggers a download under a different name.
        let id = installed.first { VoxtypeModel.matches($0, catalogID: catalogID) } ?? catalogID
        lastAttempted = catalogID
        failure = nil
        let needsDownload = !installed.contains { VoxtypeModel.matches($0, catalogID: catalogID) }
        if needsDownload {
            downloadingID = id
            downloadFraction = nil
            downloadMessage = "Downloading…"
            health?.noteModelDownload(EngineFacts.Download(model: catalogID, fraction: nil))
        }
        let runner = self.runner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                if needsDownload {
                    try runner.download(id) { event in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            switch event {
                            case .progress(let fraction, let bytesGB, let totalGB):
                                self.downloadFraction = fraction
                                self.downloadMessage = String(format: "Downloading… %.1f of %.1f GB", bytesGB, totalGB)
                                self.health?.noteModelDownload(EngineFacts.Download(model: catalogID, fraction: fraction))
                            case .failure(let message):
                                self.failure = message
                            }
                        }
                    }
                }
                try runner.setModel(id)
                guard let self else { return }
                DispatchQueue.main.async { [self] in
                    self.downloadingID = nil
                    self.installed.insert(id)
                    self.current = id
                    // Completed: clear the download indicator health reports through the menu.
                    self.health?.noteModelDownload(nil)
                    EngineControl.restart()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.downloadingID = nil
                    self.failure = error.localizedDescription
                    // Failed: also clear it, rather than leaving the menu showing a download
                    // that is no longer happening.
                    self.health?.noteModelDownload(nil)
                }
            }
        }
    }
}
