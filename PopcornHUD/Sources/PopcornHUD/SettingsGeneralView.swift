import AppKit
import SwiftUI
import PopcornCore

/// General tab (§3): startup preference, FN/Globe shortcut guidance, live setup/recovery status,
/// transcript history, and advanced config-file access.
struct SettingsGeneralView: View {
    @ObservedObject var store: SettingsStore
    let health: DictationHealthMonitor?
    /// Harness-only (`VOICEPOP_UI_SNAPSHOT`): seeds the status section without a real
    /// `DictationHealthMonitor`, so both a healthy and an issue state can be rendered offscreen.
    var fixtureStatus: DictationStatus?

    // Starts false and is corrected by an async probe in onAppear - SMAppService.status is a
    // synchronous XPC round trip and must not run on the main thread during view init.
    @State private var loginEnabled = false
    @State private var loginItemError: String?
    @State private var status = DictationStatus(daemon: .missing, facts: EngineFacts())
    @State private var showClearHistoryConfirm = false
    @State private var clearHistoryError: String?

    init(store: SettingsStore, health: DictationHealthMonitor?, fixtureStatus: DictationStatus? = nil) {
        self.store = store
        self.health = health
        self.fixtureStatus = fixtureStatus
        if let fixtureStatus { _status = State(initialValue: fixtureStatus) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open VoicePop at Login", isOn: $loginEnabled)
                    .disabled(!LoginItem.isAvailable)
                    .onChange(of: loginEnabled) { newValue in
                        // Optimistic: the switch already shows newValue. Revert it and show an
                        // inline error if the XPC call fails, instead of blocking on it here.
                        loginItemError = nil
                        LoginItem.setEnabledAsync(newValue) { result in
                            if case .failure(let error) = result {
                                loginEnabled = !newValue
                                loginItemError = error.localizedDescription
                            }
                        }
                    }
                    .accessibilityHint(LoginItem.isAvailable ? "" : loginUnavailableReason)
                if !LoginItem.isAvailable {
                    Text(loginUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Dictation shortcut") {
                Text("Hold the 🌐 (Fn/Globe) key to dictate. Set \u{201c}Press 🌐 key to: Do Nothing\u{201d} in Keyboard settings so the system doesn\u{2019}t intercept it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("Setup & recovery") {
                Label(status.headline, systemImage: status.issue == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(status.issue == nil ? Color.primary : Color.orange)
                    .accessibilityLabel(status.headline)
                ForEach(status.actions, id: \.self) { action in
                    Button(title(for: action)) { perform(action) }
                }
            }

            Section("Transcript history") {
                Button("Clear Transcript History…", role: .destructive) {
                    showClearHistoryConfirm = true
                }
                if let clearHistoryError {
                    Text(clearHistoryError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Advanced") {
                Button("Open Voxtype Configuration File") {
                    let path = NSString(string: "~/.config/voxtype/config.toml").expandingTildeInPath
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            LoginItem.isEnabledAsync { loginEnabled = $0 }
            health?.addListener { newStatus in
                status = newStatus
            }
        }
        .alert("Clear transcript history?", isPresented: $showClearHistoryConfirm) {
            Button("Clear History", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the current and rotated transcript history. Saved corrections, learned words, and writing styles stay in place.")
        }
    }

    private var loginUnavailableReason: String {
        LoginItem.isInstalledApp
            ? "Open at Login isn\u{2019}t available for this build."
            : "Open at Login is available once VoicePop is installed in /Applications."
    }

    private func title(for action: RecoveryAction) -> String {
        switch action {
        case .openSetup: return "Check Setup…"
        case .restartEngine: return "Restart Dictation Engine"
        case .retryDownload: return "Retry Download"
        case .openPrivacySettings: return "Open Privacy & Security…"
        case .openSettings: return "Open Settings…"
        case .copyLastText: return "Copy Last Text"
        }
    }

    private func perform(_ action: RecoveryAction) {
        switch action {
        case .openSetup: SetupAssistant.presentChecklist()
        case .restartEngine: EngineControl.restart()
        case .retryDownload: SettingsWindowController.shared.show(.dictation)
        case .openPrivacySettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                NSWorkspace.shared.open(url)
            }
        case .openSettings: break
        case .copyLastText:
            LastHistoryEntryCache.currentAsync { entry in
                guard let text = entry?.out else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func clearHistory() {
        do {
            try HistoryStore.clear()
            clearHistoryError = nil
        } catch {
            clearHistoryError = error.localizedDescription
        }
    }
}
