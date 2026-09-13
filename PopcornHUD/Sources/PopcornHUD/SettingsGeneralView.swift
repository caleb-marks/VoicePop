import AppKit
import SwiftUI
import PopcornCore

/// General tab (§3): startup preference, FN/Globe shortcut guidance, live setup/recovery status,
/// transcript history, and advanced config-file access. Status comes from `store.status`, which
/// `SettingsStore` observes once for the whole window (see its doc comment) rather than this view
/// adding its own permanent `DictationHealthMonitor` listener on every `onAppear`.
struct SettingsGeneralView: View {
    @ObservedObject var store: SettingsStore

    // Starts false and is corrected by an async probe in onAppear - SMAppService.status is a
    // synchronous XPC round trip and must not run on the main thread during view init.
    @State private var loginEnabled = false
    @State private var loginItemError: String?
    @State private var showClearHistoryConfirm = false
    @State private var clearHistoryError: String?

    init(store: SettingsStore) {
        self.store = store
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open VoicePop at Login", isOn: loginToggleBinding)
                    .disabled(!LoginItem.isAvailable)
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
                Label(store.status.headline, systemImage: store.status.issue == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(store.status.issue == nil ? Color.primary : Color.orange)
                    .accessibilityLabel(store.status.headline)
                // The same explanation the menu's second line shows - what's wrong and what to do.
                if let detail = store.status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // .openSetup is folded into the always-visible "Check Setup…" button below (M-3),
                // so it never appears twice.
                ForEach(store.status.actions.filter { $0 != .openSetup }, id: \.self) { action in
                    Button(title(for: action)) { perform(action) }
                }
                // Always reachable, not only when something is already wrong - §6 "Make setup
                // accessible from Settings" (M-3). README and the checklist footer both promise
                // this path exists even while everything is healthy.
                Button("Check Setup…") { SetupAssistant.presentChecklist() }
            }

            // What VoicePop keeps and where dictated text can end up. The toggle stops *new*
            // history writes (in this app and in the separate voxtype-clean process, which
            // re-reads style.json per dictation); deleting what already exists stays a separate,
            // confirmed action so turning the switch off never silently destroys data.
            Section {
                Toggle("Save transcript history", isOn: Binding(
                    get: { store.prefs.privacy.saveHistory },
                    set: { store.prefs.privacy.saveHistory = $0; store.save() }
                ))
                if let error = store.saveError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { store.save() }
                    }
                }
                Text(historyExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Clear Transcript History…", role: .destructive) {
                    showClearHistoryConfirm = true
                }
                if let clearHistoryError {
                    Text(clearHistoryError).font(.caption).foregroundStyle(.red)
                }
                Text(clipboardExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Saved corrections (corrections.jsonl) and learned words (replacements.json) are separate from transcript history. Neither the switch nor Clear Transcript History touches them; manage learned words in the Learned Words tab.")
            }

            Section {
                Button("Open Voxtype Configuration File") {
                    let path = NSString(string: "~/.config/voxtype/config.toml").expandingTildeInPath
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                // Direct file editing as an advanced action (§3) - previously only the Voxtype
                // config had this; Learned Words' own file had no such escape hatch (L-18).
                Button("Open Learned Words File") {
                    if !FileManager.default.fileExists(atPath: VoicePopPaths.replacements.path) {
                        try? Replacements().save()
                    }
                    NSWorkspace.shared.open(VoicePopPaths.replacements)
                }
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            LoginItem.isEnabledAsync { loginEnabled = $0 }
        }
        .alert("Clear transcript history?", isPresented: $showClearHistoryConfirm) {
            Button("Clear History", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the current and rotated transcript history. Saved corrections, learned words, and writing styles stay in place.")
        }
    }

    /// The *only* path that calls `LoginItem.setEnabledAsync` (H-1). A plain `@State` + `onChange`
    /// pair also fires `onChange` for the programmatic writes `onAppear`'s probe and this
    /// binding's own failure-revert perform - which previously meant opening Settings, or a
    /// failed toggle, called `register()`/`unregister()` again and could ping-pong. Writing
    /// `loginEnabled` directly (as `onAppear` and the revert below do) is a plain `@State`
    /// mutation that never re-enters this `set`.
    private var loginToggleBinding: Binding<Bool> {
        Binding(
            get: { loginEnabled },
            set: { newValue in
                loginEnabled = newValue
                loginItemError = nil
                LoginItem.setEnabledAsync(newValue) { result in
                    if case .failure(let error) = result {
                        loginEnabled = !newValue
                        loginItemError = error.localizedDescription
                    }
                }
            }
        )
    }

    private var historyExplanation: String {
        store.prefs.privacy.saveHistory
            ? "Each dictation is appended to history.jsonl in ~/.config/voicepop (owner-only). Fix Last Dictation and Copy Last Text read the newest entry. Turning this off stops new entries; existing ones stay until you clear them."
            : "New dictations are not being recorded, in this app or by the voxtype-clean step. Fix Last Dictation and Copy Last Text can only offer dictations saved before this was turned off. Existing entries stay until you clear them."
    }

    /// Accurate to Voxtype's output chain with VoicePop's config (`fallback_to_clipboard = true`):
    /// CGEvent typing, then AppleScript typing, then a silent copy to the clipboard. VoicePop
    /// adds no clipboard protection of its own.
    private var clipboardExplanation: String {
        "Clipboard: dictated text is typed into the focused app. If typing fails (for example Voxtype lacks Accessibility permission), Voxtype copies the text to the system clipboard instead, replacing what was there, with no notice. Copy Last Text and Copy Corrected Text also put text on the clipboard when you choose them. VoicePop never clears or restores the clipboard."
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
        // Already inside Settings, so "Open Settings…" only makes sense as "go to the tab with
        // more detail" (L-11) - previously a no-op.
        case .openSettings: SettingsWindowController.shared.show(.dictation)
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
            // Otherwise the menu's "Fix Last Dictation…" and Copy Last Text keep showing the
            // just-deleted transcript until something else happens to trigger a reload (L-3).
            LastHistoryEntryCache.clear()
            clearHistoryError = nil
        } catch {
            clearHistoryError = error.localizedDescription
        }
    }
}
