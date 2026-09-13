import AppKit
import Darwin
import PopcornCore

/// Native popcorn menu-bar status item; replaces Voxtype's emoji tray.
///
/// Menu hierarchy (§3): status headline (+ optional model detail line) with recovery actions
/// driven by `DictationStatus.actions`, Start/Stop Recording, Cancel Recording, Fix Last
/// Dictation, Writing Style, Settings…, Quit. Model choice, mascot, open-at-login, restart,
/// config-file editing, learned words, transcript history, and the Ollama toggle all moved into
/// the Settings window - the old "More" submenu is gone, but every capability stays reachable.
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var detailMenuItem: NSMenuItem?
    private var recoveryItems: [NSMenuItem] = []
    private var recoverySeparator: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var cancelMenuItem: NSMenuItem?
    private var lastState: DaemonState = .idle
    private var lastStatus = DictationStatus(daemon: .missing, facts: EngineFacts())
    private var prefs = StylePrefsCache.current()
    private var targetApp = ""
    private var globalStyleItems: [Style: NSMenuItem] = [:]
    private var appStyleItems: [String: NSMenuItem] = [:]   // keys "default", "casual", "formal"
    private var appHeaderItem: NSMenuItem?
    private var cachedCurrentModel: String?
    private var refreshInFlight = false
    private var modelCacheStamp = Date.distantPast
    private static let modelCacheTTL: TimeInterval = 5
    private var modelShortTitle: String?
    private var fixLastMenuItem: NSMenuItem?
    private var watcher: StateWatcher?
    private var health: DictationHealthMonitor?

    func start(watcher: StateWatcher, health: DictationHealthMonitor) {
        self.health = health
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            button.image = StatusItemIcon.image(pointSize: 18, mascot: prefs.mascot)
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "VoicePop"
            button.setAccessibilityLabel("VoicePop")
        }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        self.watcher = watcher
        watcher.addListener { [weak self] state in
            self?.apply(state: state)
        }
        // The headline must never say "Ready" while a known issue blocks dictation - drive it
        // from DictationStatus, not from DaemonState alone.
        health.addListener { [weak self] status in
            self?.apply(status: status)
        }

        // Nothing else launches the daemon after a reboot or logout: bring it up
        // ourselves, or FN does nothing until the user picks "Restart Dictation Engine".
        EngineControl.startIfNotRunning()

        // Process discovery must not block HUD startup on the main thread.
        EngineControl.scheduleMenubarSuppressRetries()
        refreshCachesIfStale(force: true)
        reloadFixLastItem()
        observeTranscriptReady()
        VoxtypeWarmer.shared.ensureWarm()
    }

    @discardableResult
    func revealMenu() -> Bool {
        guard let item = statusItem, let button = item.button, item.isVisible, button.window != nil else {
            fputs("VoicePop status item overflow or missing\n", stderr)
            return false
        }
        button.performClick(nil)
        return true
    }

    func stop() {
        EngineControl.cancelMenubarSuppressRetries()
        watcher = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// A finished transcription is exactly when "Fix Last Dictation" needs a fresh title -
    /// cheaper and more precise than only reloading on idle transitions.
    private func observeTranscriptReady() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<StatusItemController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { controller.reloadFixLastItem() }
            },
            VoicePopSignal.transcriptReady as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - State

    /// Harness-only (`VOICEPOP_UI_SNAPSHOT`): builds the menu and applies fixture state, without
    /// any of `start(watcher:health:)`'s live side effects (no engine probing, no warmer, no
    /// daemon start). Titles/enabled/hidden states can then be logged for inspection - a real
    /// `NSMenu` attached to a status item can't be screenshotted meaningfully offscreen.
    func menuForSnapshot(state: DaemonState, status: DictationStatus) -> NSMenu {
        let menu = buildMenu()
        for item in menu.items where item.action != nil { item.target = self }
        lastState = state
        recordMenuItem?.title = state.isHot ? "Stop Recording" : "Start Recording"
        cancelMenuItem?.isHidden = !state.isHot
        cancelMenuItem?.isEnabled = state.isHot
        lastStatus = status
        statusMenuItem?.title = status.headline
        rebuildRecoveryItemsForSnapshot(in: menu, actions: status.actions)
        return menu
    }

    /// `rebuildRecoveryItems` looks up `statusItem?.menu`, which is nil in the harness (no real
    /// status item exists). This variant takes the menu explicitly.
    private func rebuildRecoveryItemsForSnapshot(in menu: NSMenu, actions: [RecoveryAction]) {
        guard let separator = recoverySeparator, let sepIndex = menu.items.firstIndex(of: separator) else { return }
        var insertAt = sepIndex
        for action in actions {
            let item = NSMenuItem(title: title(for: action), action: nil, keyEquivalent: "")
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
        separator.isHidden = actions.isEmpty
    }

    private func apply(state: DaemonState) {
        if state.isHot && !lastState.isHot, OllamaWarmer.formalInEffect(prefs) {
            OllamaWarmer.shared.ensureWarm(prefs.llm)
        }
        lastState = state
        recordMenuItem?.title = state.isHot ? "Stop Recording" : "Start Recording"
        cancelMenuItem?.isHidden = !state.isHot
        cancelMenuItem?.isEnabled = state.isHot
        if !state.isHot, !state.isTranscribing {
            reloadFixLastItem()
        }
    }

    /// Applies the shared `DictationStatus` headline/actions - the single source of truth for
    /// whether the menu is allowed to say "Ready".
    private func apply(status: DictationStatus) {
        lastStatus = status
        statusMenuItem?.title = status.headline
        statusMenuItem?.setAccessibilityLabel(status.headline)
        if let title = modelShortTitle, status.issue == nil {
            detailMenuItem?.title = title
            detailMenuItem?.isHidden = false
        } else {
            detailMenuItem?.isHidden = true
        }
        rebuildRecoveryItems(for: status.actions)
    }

    private static func styleTitle(_ style: Style) -> String {
        switch style {
        case .auto: return "Automatic"
        case .casual: return "Casual"
        case .formal: return "Formal"
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Ready · Hold FN to dictate", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)

        let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        detail.isHidden = true
        detailMenuItem = detail
        menu.addItem(detail)

        // Recovery items are inserted here dynamically, followed by their own separator.
        let recoverySep = NSMenuItem.separator()
        recoverySep.isHidden = true
        recoverySeparator = recoverySep
        menu.addItem(recoverySep)

        menu.addItem(.separator())

        let record = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        recordMenuItem = record
        menu.addItem(record)

        let cancel = NSMenuItem(title: "Cancel Recording", action: #selector(cancelRecording), keyEquivalent: "")
        cancel.isHidden = true
        cancel.isEnabled = false
        cancelMenuItem = cancel
        menu.addItem(cancel)

        let fix = NSMenuItem(title: "Fix Last Dictation…", action: #selector(fixLastDictation), keyEquivalent: "")
        fixLastMenuItem = fix
        menu.addItem(fix)

        let styleItem = NSMenuItem(title: "Writing Style", action: nil, keyEquivalent: "")
        styleItem.submenu = buildStyleMenu()
        menu.addItem(styleItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit VoicePop", action: #selector(quitHUD), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    private func buildStyleMenu() -> NSMenu {
        let menu = NSMenu()
        for style in Style.allCases {
            let item = NSMenuItem(title: Self.styleTitle(style), action: #selector(setGlobalStyle(_:)), keyEquivalent: "")
            item.representedObject = style.rawValue
            item.target = self
            globalStyleItems[style] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let header = NSMenuItem(title: "This app:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        appHeaderItem = header
        menu.addItem(header)

        let defaultItem = NSMenuItem(title: "Same as above", action: #selector(setAppStyle(_:)), keyEquivalent: "")
        defaultItem.representedObject = nil
        defaultItem.target = self
        appStyleItems["default"] = defaultItem
        menu.addItem(defaultItem)

        for style in [Style.casual, .formal] {
            let item = NSMenuItem(title: Self.styleTitle(style), action: #selector(setAppStyle(_:)), keyEquivalent: "")
            item.representedObject = style.rawValue
            item.target = self
            appStyleItems[style.rawValue] = item
            menu.addItem(item)
        }
        return menu
    }

    /// Rebuilds the dynamic recovery-action items in place, right after the status/detail lines.
    private func rebuildRecoveryItems(for actions: [RecoveryAction]) {
        guard let menu = statusItem?.menu, let separator = recoverySeparator,
              let sepIndex = menu.items.firstIndex(of: separator) else { return }
        for item in recoveryItems { menu.removeItem(item) }
        recoveryItems.removeAll()
        var insertAt = sepIndex
        for action in actions {
            let item = NSMenuItem(title: title(for: action), action: #selector(performRecovery(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.target = self
            menu.insertItem(item, at: insertAt)
            recoveryItems.append(item)
            insertAt += 1
        }
        recoverySeparator?.isHidden = actions.isEmpty
    }

    private func title(for action: RecoveryAction) -> String {
        switch action {
        case .openSetup: return "Open Setup…"
        case .restartEngine: return "Restart Dictation Engine"
        case .retryDownload: return "Retry Download"
        case .openPrivacySettings: return "Open Privacy & Security…"
        case .openSettings: return "Open Settings…"
        case .copyLastText: return "Copy Last Text"
        }
    }

    @MainActor @objc private func performRecovery(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = RecoveryAction(rawValue: raw) else { return }
        switch action {
        case .openSetup: SetupAssistant.presentChecklist()
        case .restartEngine: EngineControl.restart()
        case .retryDownload: SettingsWindowController.shared.show(.dictation)
        case .openPrivacySettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                NSWorkspace.shared.open(url)
            }
        case .openSettings: SettingsWindowController.shared.show()
        case .copyLastText:
            LastHistoryEntryCache.currentAsync { entry in
                guard let text = entry?.out else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    @objc private func toggleRecording() {
        EngineControl.record(.toggle)
    }

    @objc private func cancelRecording() {
        EngineControl.record(.cancel)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        prefs = StylePrefsCache.current()
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != PopcornHUDMain.bundleID {
            targetApp = front.localizedName ?? ""
        }
        for (style, item) in globalStyleItems { item.state = prefs.global == style ? .on : .off }
        appHeaderItem?.title = targetApp.isEmpty ? "This app:" : "This app - \(targetApp)"
        recordMenuItem?.title = lastState.isHot ? "Stop Recording" : "Start Recording"
        cancelMenuItem?.isHidden = !lastState.isHot
        cancelMenuItem?.isEnabled = lastState.isHot
        let override = prefs.perApp.first { $0.key.caseInsensitiveCompare(targetApp) == .orderedSame }?.value
        appStyleItems["default"]?.state = override == nil ? .on : .off
        appStyleItems["casual"]?.state = override == .casual ? .on : .off
        appStyleItems["formal"]?.state = override == .formal ? .on : .off
        appStyleItems.values.forEach { $0.isEnabled = !targetApp.isEmpty }
        refreshMascotIcon()
        refreshCachesIfStale()
        refreshFixLastItem()
        // Pick up hand edits to style.json / a dictation since the last open, off the main
        // thread, for the *next* open (this one paints from whatever is already cached).
        StylePrefsCache.refreshAsync()
        reloadFixLastItem()
        statusItem?.button?.toolTip = "VoicePop - \(prefs.resolve(app: targetApp).rawValue.capitalized)"
    }

    /// Refreshes the cached current-model title (for the menu's disabled detail line) off the
    /// main thread when stale. Two `voxtype-bin` spawns used to happen synchronously on the main
    /// thread on every menu open; now they happen at most once every `modelCacheTTL` seconds.
    private func refreshCachesIfStale(force: Bool = false) {
        guard force || Date().timeIntervalSince(modelCacheStamp) > Self.modelCacheTTL else { return }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let current = VoxtypeModel.currentModel()
            DispatchQueue.main.async {
                guard let self else { return }
                self.cachedCurrentModel = current
                self.modelShortTitle = current.map(VoxtypeModel.title(for:))
                self.modelCacheStamp = Date()
                self.refreshInFlight = false
                self.apply(status: self.lastStatus)
            }
        }
    }

    @objc private func setGlobalStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = Style(rawValue: raw) else { return }
        prefs.global = style
        savePrefs()
    }
    @objc private func setAppStyle(_ sender: NSMenuItem) {
        guard !targetApp.isEmpty else { return }
        prefs.perApp = prefs.perApp.filter { $0.key.caseInsensitiveCompare(targetApp) != .orderedSame }
        if let raw = sender.representedObject as? String, let style = Style(rawValue: raw) { prefs.perApp[targetApp] = style }
        savePrefs()
    }
    private func refreshMascotIcon() {
        statusItem?.button?.image = StatusItemIcon.image(pointSize: 18, mascot: prefs.mascot)
    }
    private func savePrefs() {
        do {
            try prefs.save()
            StylePrefsCache.store(prefs)
            // So an open Settings window (SettingsStore) refreshes instead of showing a stale
            // value or later overwriting this change with what it had before.
            NotificationCenter.default.post(name: .voicePopStylePrefsDidChange, object: nil)
        } catch {
            fputs("VoicePop: style.json save failed: \(error)\n", stderr)
        }
        if OllamaWarmer.formalInEffect(prefs) { OllamaWarmer.shared.ensureWarm(prefs.llm) }
    }
    /// Pure UI, no I/O: paints `fixLastMenuItem` from whatever `LastHistoryEntryCache` already
    /// holds in memory. Never touches `history.jsonl` on the main thread.
    private func refreshFixLastItem() {
        guard let out = LastHistoryEntryCache.current()?.out.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            fixLastMenuItem?.title = "Fix Last Dictation…"
            return
        }
        let clip = out.count > 28 ? String(out.prefix(27)) + "…" : out
        fixLastMenuItem?.title = "Fix \u{201c}\(clip)\u{201d}…"
    }

    /// Re-reads `history.jsonl` off the main thread (idle transitions, transcript-ready, menu
    /// open) and repaints once the cache updates.
    private func reloadFixLastItem() {
        LastHistoryEntryCache.refreshAsync { [weak self] _ in
            self?.refreshFixLastItem()
        }
    }

    @objc private func fixLastDictation() { CorrectionWindowController.shared.present() }

    @objc private func quitHUD() {
        NSApp.terminate(nil)
    }
}
