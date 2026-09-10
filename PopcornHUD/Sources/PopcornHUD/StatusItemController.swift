import AppKit
import Darwin
import PopcornCore

/// Native popcorn menu-bar status item; replaces Voxtype's emoji tray.
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var cancelMenuItem: NSMenuItem?
    private var loginItemMenuItem: NSMenuItem?
    private var lastState: DaemonState = .idle
    private var prefs = StylePrefsCache.current()
    private var targetApp = ""
    private var globalStyleItems: [Style: NSMenuItem] = [:]
    private var appStyleItems: [String: NSMenuItem] = [:]   // keys "default", "casual", "formal"
    private var appHeaderItem: NSMenuItem?
    private var llmToggleItem: NSMenuItem?
    private var mascotItems: [Mascot: NSMenuItem] = [:]
    private var modelMenuItem: NSMenuItem?
    private var modelItems: [String: NSMenuItem] = [:]
    private var modelDownloading = false
    private var cachedInstalled: Set<String> = []
    private var cachedCurrentModel: String?
    private var cachedLoginEnabled = false
    private var refreshInFlight = false
    private var modelCacheStamp = Date.distantPast
    private static let modelCacheTTL: TimeInterval = 5
    private var modelShortTitle = "Small"
    private var fixLastMenuItem: NSMenuItem?
    private var watcher: StateWatcher?
    private var suppressTimer: DispatchSourceTimer?
    private static let voxtypeBin = "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"
    private static let restartScriptDefaultsKey = "restartVoxtypeScript"

    func start(watcher: StateWatcher) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            button.image = StatusItemIcon.image(pointSize: 18, mascot: prefs.mascot)
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "VoicePop"
        }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        self.watcher = watcher
        watcher.addListener { [weak self] state in
            self?.apply(state: state)
        }

        // Process discovery must not block HUD startup on the main thread.
        scheduleMenubarSuppressRetries()
        refreshCachesIfStale(force: true)
        statusMenuItem?.title = statusTitle(for: lastState)
        refreshFixLastItem()
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
        suppressTimer?.cancel()
        suppressTimer = nil
        watcher = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - State

    private func apply(state: DaemonState) {
        if state.isHot && !lastState.isHot, OllamaWarmer.formalInEffect(prefs) {
            OllamaWarmer.shared.ensureWarm(prefs.llm)
        }
        lastState = state
        statusMenuItem?.title = statusTitle(for: state)
        recordMenuItem?.title = state.isHot ? "Stop Recording" : "Start Recording"
        cancelMenuItem?.isEnabled = state.isHot
        if !state.isHot, !state.isTranscribing {
            refreshFixLastItem()
        }
    }

    private func statusTitle(for state: DaemonState) -> String {
        switch state {
        case .recording: return "Recording…"
        case .streaming: return "Listening…"
        case .transcribing: return "Typing…"
        case .idle: return "Ready · \(modelShortTitle)"
        case .missing: return "Dictation isn’t running"
        case .other(let s): return s
        }
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

        let status = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)
        menu.addItem(.separator())

        let styleItem = NSMenuItem(title: "Writing style", action: nil, keyEquivalent: "")
        styleItem.submenu = buildStyleMenu()
        menu.addItem(styleItem)
        let modelItem = NSMenuItem(title: "Dictation model", action: nil, keyEquivalent: "")
        modelItem.submenu = buildModelMenu()
        modelMenuItem = modelItem
        menu.addItem(modelItem)
        let fix = NSMenuItem(title: "Fix last text…", action: #selector(fixLastDictation), keyEquivalent: "")
        fixLastMenuItem = fix
        menu.addItem(fix)
        menu.addItem(.separator())

        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.submenu = buildMoreMenu()
        menu.addItem(more)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit VoicePop",
            action: #selector(quitHUD),
            keyEquivalent: "q"
        ))

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
        return menu
    }

    private func buildModelMenu() -> NSMenu {
        let menu = NSMenu()
        for choice in VoxtypeModel.catalog {
            let item = NSMenuItem(title: choice.title, action: #selector(setDictationModel(_:)), keyEquivalent: "")
            item.representedObject = choice.id
            item.target = self
            modelItems[choice.id] = item
            menu.addItem(item)
        }
        return menu
    }

    private func buildMoreMenu() -> NSMenu {
        let menu = NSMenu()

        let record = NSMenuItem(
            title: "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        record.target = self
        recordMenuItem = record
        menu.addItem(record)
        let cancel = NSMenuItem(
            title: "Cancel",
            action: #selector(cancelRecording),
            keyEquivalent: ""
        )
        cancel.target = self
        cancel.isEnabled = false
        cancelMenuItem = cancel
        menu.addItem(cancel)
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

        let llm = NSMenuItem(
            title: "Polish Formal with AI",
            action: #selector(toggleLLM),
            keyEquivalent: ""
        )
        llm.target = self
        llmToggleItem = llm
        menu.addItem(llm)
        menu.addItem(.separator())

        let mascotHeader = NSMenuItem(title: "Mascot", action: nil, keyEquivalent: "")
        mascotHeader.isEnabled = false
        menu.addItem(mascotHeader)
        for mascot in Mascot.allCases {
            let title = mascot == .popcorn ? "Popcorn bucket" : "Nandor the beagle"
            let item = NSMenuItem(title: title, action: #selector(setMascot(_:)), keyEquivalent: "")
            item.representedObject = mascot.rawValue
            item.target = self
            mascotItems[mascot] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        login.target = self
        cachedLoginEnabled = LoginItem.isEnabled
        login.state = cachedLoginEnabled ? .on : .off
        login.isEnabled = LoginItem.isAvailable
        loginItemMenuItem = login
        menu.addItem(login)
        let restart = NSMenuItem(title: "Restart dictation", action: #selector(restartVoxtype), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
        let settings = NSMenuItem(title: "Open settings file…", action: #selector(editConfig), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let learned = NSMenuItem(title: "Edit learned words…", action: #selector(openLearnedCorrections), keyEquivalent: "")
        learned.target = self
        menu.addItem(learned)
        return menu
    }

    @objc private func toggleRecording() {
        runVoxtype(["record", "toggle"])
    }

    @objc private func cancelRecording() {
        runVoxtype(["record", "cancel"])
    }

    @objc private func editConfig() {
        let path = NSString(string: "~/.config/voxtype/config.toml").expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItemMenuItem?.state = cachedLoginEnabled ? .on : .off
        loginItemMenuItem?.isEnabled = LoginItem.isAvailable
        prefs = StylePrefsCache.current()
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != PopcornHUDMain.bundleID {
            targetApp = front.localizedName ?? ""
        }
        for (style, item) in globalStyleItems { item.state = prefs.global == style ? .on : .off }
        appHeaderItem?.title = targetApp.isEmpty ? "This app:" : "This app — \(targetApp)"
        recordMenuItem?.title = lastState.isHot ? "Stop Recording" : "Start Recording"
        cancelMenuItem?.isEnabled = lastState.isHot
        let override = prefs.perApp.first { $0.key.caseInsensitiveCompare(targetApp) == .orderedSame }?.value
        appStyleItems["default"]?.state = override == nil ? .on : .off
        appStyleItems["casual"]?.state = override == .casual ? .on : .off
        appStyleItems["formal"]?.state = override == .formal ? .on : .off
        appStyleItems.values.forEach { $0.isEnabled = !targetApp.isEmpty }
        llmToggleItem?.state = prefs.llm.enabled ? .on : .off
        for (mascot, item) in mascotItems { item.state = prefs.mascot == mascot ? .on : .off }
        refreshMascotIcon()
        applyModelMenuState()
        refreshCachesIfStale()
        refreshFixLastItem()
        // Pick up hand edits to style.json for the *next* open, off the main thread.
        StylePrefsCache.refreshAsync()
        statusItem?.button?.toolTip = "VoicePop — \(prefs.resolve(app: targetApp).rawValue.capitalized) · \(modelShortTitle)"
    }

    /// Pure UI, no I/O: paints `modelMenuItem` / `modelItems` / `modelShortTitle` / the idle status
    /// title from whatever `cachedInstalled` / `cachedCurrentModel` already hold.
    private func applyModelMenuState() {
        let current = cachedCurrentModel
        if let current {
            modelShortTitle = VoxtypeModel.title(for: current)
        }
        if lastState == .idle {
            statusMenuItem?.title = statusTitle(for: .idle)
        }
        modelMenuItem?.title = modelDownloading ? "Dictation model (downloading…)" : "Dictation model"
        for (id, item) in modelItems {
            item.state = current == id ? .on : .off
            item.isEnabled = !modelDownloading
        }
    }

    /// Refreshes `cachedInstalled` / `cachedCurrentModel` / `cachedLoginEnabled` off the main
    /// thread when the cache is stale (or `force`d), then applies the result on main. Two
    /// `voxtype-bin` spawns plus a `SMAppService` XPC call used to happen synchronously on the
    /// main thread on every menu open; now they happen at most once every `modelCacheTTL` seconds,
    /// off-main.
    private func refreshCachesIfStale(force: Bool = false) {
        guard force || Date().timeIntervalSince(modelCacheStamp) > Self.modelCacheTTL else { return }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let installed = self.modelDownloading ? nil : VoxtypeModel.installedNames()
            let current = VoxtypeModel.currentModel()
            let loginEnabled = LoginItem.isEnabled
            DispatchQueue.main.async {
                if let installed {
                    self.cachedInstalled = installed
                }
                self.cachedCurrentModel = current
                self.cachedLoginEnabled = loginEnabled
                self.modelCacheStamp = Date()
                self.refreshInFlight = false
                self.applyModelMenuState()
                self.loginItemMenuItem?.state = self.cachedLoginEnabled ? .on : .off
            }
        }
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        cachedLoginEnabled = LoginItem.isEnabled
        loginItemMenuItem?.state = cachedLoginEnabled ? .on : .off
    }

    @objc private func setDictationModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, !modelDownloading else { return }
        if VoxtypeModel.currentModel() == name { return }
        if cachedInstalled.isEmpty { cachedInstalled = VoxtypeModel.installedNames() }
        let needsDownload = !cachedInstalled.contains(name)
        modelDownloading = needsDownload
        applyModelMenuState()
        modelItems.values.forEach { $0.isEnabled = false }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                if needsDownload {
                    try VoxtypeModel.download(name)
                }
                try VoxtypeModel.setModel(name)
                DispatchQueue.main.async {
                    self?.modelDownloading = false
                    self?.modelShortTitle = VoxtypeModel.title(for: name)
                    self?.applyModelMenuState()
                    self?.refreshCachesIfStale(force: true)
                    self?.restartVoxtype()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.modelDownloading = false
                    self?.applyModelMenuState()
                    self?.refreshCachesIfStale(force: true)
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t switch dictation model"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
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
    @objc private func toggleLLM() { prefs.llm.enabled.toggle(); savePrefs() }
    @objc private func setMascot(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mascot = Mascot(rawValue: raw) else { return }
        prefs.mascot = mascot
        savePrefs()
        refreshMascotIcon()
        NotificationCenter.default.post(name: .voicePopMascotDidChange, object: mascot)
    }
    private func refreshMascotIcon() {
        statusItem?.button?.image = StatusItemIcon.image(pointSize: 18, mascot: prefs.mascot)
    }
    private func savePrefs() {
        do {
            try prefs.save()
            StylePrefsCache.store(prefs)
        } catch {
            fputs("VoicePop: style.json save failed: \(error)\n", stderr)
        }
        if OllamaWarmer.formalInEffect(prefs) { OllamaWarmer.shared.ensureWarm(prefs.llm) }
    }
    private func refreshFixLastItem() {
        guard let out = HistoryStore.last()?.out.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            fixLastMenuItem?.title = "Fix last text…"
            return
        }
        let clip = out.count > 28 ? String(out.prefix(27)) + "…" : out
        fixLastMenuItem?.title = "Fix “\(clip)”…"
    }

    @objc private func fixLastDictation() { CorrectionWindowController.shared.present() }
    @objc private func openLearnedCorrections() {
        if !FileManager.default.fileExists(atPath: VoicePopPaths.replacements.path) { try? Replacements().save() }
        NSWorkspace.shared.open(VoicePopPaths.replacements)
    }

    private static func restartScriptPath() -> String? {
        if let bundled = Bundle.main.url(forResource: "restart-voxtype", withExtension: "sh")?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        if let custom = UserDefaults.standard.string(forKey: restartScriptDefaultsKey),
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        let fallback = NSHomeDirectory() + "/VoicePop/scripts/restart-voxtype.sh"
        if FileManager.default.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return nil
    }

    @objc private func restartVoxtype() {
        if let script = Self.restartScriptPath() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: script)
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
        } else {
            // Fallback: kill all, reopen app bundle, then suppress emoji tray.
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-x", "voxtype-bin"]
            try? kill.run()
            kill.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/Applications/Voxtype.app"),
                    configuration: NSWorkspace.OpenConfiguration()
                )
                self.scheduleMenubarSuppressRetries()
            }
        }
    }

    @objc private func quitHUD() {
        NSApp.terminate(nil)
    }

    private func runVoxtype(_ args: [String]) {
        let bin = Self.voxtypeBin
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    // MARK: - Suppress Voxtype emoji tray

    /// Voxtype AppLaunch = daemon child + menubar parent. Kill parent only.
    static func suppressVoxtypeMenubar() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,args="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return
        }
        // Drain while ps is running: waiting first can deadlock on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return }

        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("voxtype-bin") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let pidStr = parts.first, let pid = Int32(pidStr) else { continue }
            let args = parts.count > 1 ? String(parts[1]) : ""
            // Keep daemon and one-shot CLI (`record`, `setup`, …).
            // Kill bare AppLaunch parent (`…/voxtype-bin`) and explicit `menubar`.
            let isBareAppLaunch = args.hasSuffix("/voxtype-bin") || args == "voxtype-bin"
            let isMenubar = args.contains("voxtype-bin menubar")
            if isBareAppLaunch || isMenubar {
                kill(pid, SIGTERM)
            }
        }
    }

    private func scheduleMenubarSuppressRetries() {
        suppressTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Voxtype may start after us; retry a few times then once more late.
        var remaining = 8
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            Self.suppressVoxtypeMenubar()
            remaining -= 1
            if remaining <= 0 {
                timer.cancel()
                DispatchQueue.main.async { self?.suppressTimer = nil }
            }
        }
        suppressTimer = timer
        timer.resume()
    }
}
