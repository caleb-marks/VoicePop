import AppKit
import SwiftUI
import PopcornCore

/// Implements `VOICEPOP_UI_SNAPSHOT` (see the delimited hook in `App.swift` and INTERFACES.md).
/// Renders every WS2 view offscreen in light and dark appearance and writes PNGs, so layout,
/// clipping, spacing, and contrast can be inspected without ever running the live app (no
/// services, no engine calls, no network). Also logs the main menu's item titles/enabled/hidden
/// states for a few fixture statuses (a real `NSMenu` on a status item can't be screenshotted
/// meaningfully offscreen) and the key-view loop for each Settings tab and the correction window.
@MainActor
enum UISnapshotHarness {
    static func run(outputDirectory: String) {
        let outDir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        seedFixtures()

        var log: [String] = []
        renderSettingsGeneral(to: outDir, log: &log)
        renderSettingsAppearance(to: outDir, log: &log)
        renderSettingsDictation(to: outDir, log: &log)
        renderLearnedWords(to: outDir, log: &log)
        renderCorrectionWindow(to: outDir, log: &log)
        renderSetupChecklist(to: outDir, log: &log)
        logMenuStates(to: outDir, log: &log)
        verifyEditorRecovery(log: &log)
        logKeyboardNavigation(to: outDir, log: &log)

        let logURL = outDir.appendingPathComponent("harness-log.txt")
        try? log.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        fputs("VoicePop UI snapshot harness: wrote \(outDir.path)\n", stderr)
    }

    // MARK: - Fixtures

    /// Writes fixture data into `VOICEPOP_CONFIG_DIR` (set by the caller - see the report for the
    /// exact invocation). `App.swift`'s harness entry point refuses to run at all unless
    /// `VOICEPOP_CONFIG_DIR` is set to something other than the real `~/.config/voicepop`, so by
    /// the time this runs the override is already guaranteed - this function does not re-check it
    /// and would overwrite live data if that guard were ever bypassed.
    private static func seedFixtures() {
        var style = StylePrefs()
        style.global = .casual
        style.perApp = ["Ghostty": .formal, "Notes": .casual]
        try? style.save()
        StylePrefsCache.store(style)

        let now = ISO8601DateFormatter().string(from: Date())
        HistoryStore.append(HistoryEntry(
            ts: now, app: "Ghostty", style: "casual",
            raw: "the kwik brown fox jumps over the lazy dog",
            rules: "the quick brown fox jumps over the lazy dog",
            out: "The quick brown fox jumps over the lazy dog.",
            llm: false
        ))

        var replacements = Replacements()
        let words: [(String, String)] = [
            ("teh", "the"), ("recieve", "receive"), ("voicepop", "VoicePop"),
            ("ghostty", "Ghostty"), ("voxtype", "Voxtype"), ("parakeet", "Parakeet"),
            ("kubernetes", "Kubernetes"), ("nandor", "Nandor"),
        ]
        for (i, pair) in words.enumerated() {
            replacements.entries.append(Replacement(from: pair.0, to: pair.1, count: i + 1, lastTs: now))
        }
        try? replacements.save()
    }

    private static func verifyEditorRecovery(log: inout [String]) {
        let editor = CorrectionWindowController.shared
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        // present() always re-reads history.jsonl for real (L-4), never trusting a seeded cache
        // value - so this must use the *actual* fixture entry seedFixtures() wrote there, or a
        // mismatched ts would take the "different entry" branch and, since the text was just
        // marked dirty, block forever on the confirmation NSAlert's modal runModal() with no one
        // to click it. (An earlier version of this check used a synthetic entry and hung the
        // harness for exactly this reason - confirmed by running it.)
        guard let entry = HistoryStore.last() else {
            log.append("FAIL: verifyEditorRecovery found no seeded history entry")
            return
        }
        editor.presentFixture(entry: entry, correctedText: entry.out)
        guard let content = editor.window?.contentView,
              let text = textViews(content).first else {
            log.append("FAIL: verifyEditorRecovery could not find the correction editor's text view")
            return
        }
        text.string = "Edited by the harness."
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
        editor.present()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        if text.string == "Edited by the harness." {
            log.append("PASS: reopening correction for the same entry preserves the edited text")
        } else {
            log.append("FAIL: reopening correction for the same entry discarded edits (got \"\(text.string)\")")
        }

        let model = LearnedWordsViewModel()
        model.load()
        guard let old = model.entries.first else {
            log.append("FAIL: verifyEditorRecovery missing learned-word fixture")
            return
        }
        var updated = Replacements.load()
        updated.entries.append(Replacement(from: "concurrentword", to: "ConcurrentWord", count: 1, lastTs: "fixture"))
        try? updated.save()
        model.delete(old)
        if Replacements.load().entries.contains(where: { $0.from == "concurrentword" }) {
            log.append("PASS: learned-word edits preserve a concurrently-added word")
        } else {
            log.append("FAIL: learned-word edit lost a concurrently-added word")
        }

        // N2-M3: a save failure must not drop the edit just because a later edit succeeds.
        // Corrupt the file mid-session, queue a failing edit, then repair the file and queue a
        // second edit - both must land, not just the second.
        guard let valid = try? Data(contentsOf: VoicePopPaths.replacements) else {
            log.append("FAIL: verifyEditorRecovery could not read replacements.json")
            return
        }
        let malformed = Data("{broken".utf8)
        try? malformed.write(to: VoicePopPaths.replacements)
        _ = model.add(from: "firstword", to: "first phrase")
        let switchedToMalformed = model.loadState == .malformed
        try? valid.write(to: VoicePopPaths.replacements)
        model.retrySave()
        _ = model.add(from: "secondword", to: "second phrase")
        let onDisk = Replacements.load().entries.map(\.from)
        if switchedToMalformed, onDisk.contains("firstword"), onDisk.contains("secondword") {
            log.append("PASS: a failed edit is retried and kept alongside a later successful one (N2-M3)")
        } else {
            log.append("FAIL: N2-M3 queue check - switchedToMalformed=\(switchedToMalformed) onDisk=\(onDisk)")
        }
    }

    // MARK: - Rendering

    private static func renderSettingsGeneral(to outDir: URL, log: inout [String]) {
        let healthy = DictationStatus(daemon: .idle, facts: EngineFacts(modelInstalled: true))
        let issue = DictationStatus(daemon: .missing, facts: EngineFacts())
        let healthyStore = SettingsStore()
        healthyStore.status = healthy
        capture(name: "settings-general-healthy", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsGeneralView(store: healthyStore)
        }
        let issueStore = SettingsStore()
        issueStore.status = issue
        capture(name: "settings-general-issue", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsGeneralView(store: issueStore)
        }
    }

    private static func renderSettingsAppearance(to outDir: URL, log: inout [String]) {
        let engine = AppearancePreviewEngine()
        engine.setIntensity(.energetic)
        engine.preroll(seconds: 2, mascot: .popcorn)
        capture(name: "settings-appearance", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsAppearanceView(store: SettingsStore(), fixtureEngine: engine)
        }
        log.append("settings-appearance: engine.advanceCount after 2s preroll = \(engine.advanceCount)")
    }

    private static func renderSettingsDictation(to outDir: URL, log: inout [String]) {
        let downloading = ModelListViewModel()
        downloading.skipAutoRefresh = true
        downloading.current = nil
        downloading.installed = []
        downloading.downloadingID = "large-v3-turbo"
        downloading.downloadFraction = 0.4
        downloading.downloadMessage = "Downloading… 0.6 of 1.6 GB"
        capture(name: "settings-dictation-downloading", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsDictationView(store: SettingsStore(), fixtureModels: downloading)
        }

        let failed = ModelListViewModel()
        failed.skipAutoRefresh = true
        failed.current = "parakeet-tdt-0.6b-v3-int8-prepacked"
        failed.installed = ["parakeet-tdt-0.6b-v3-int8-prepacked"]
        failed.failure = "The network connection was lost."
        capture(name: "settings-dictation-failed", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsDictationView(store: SettingsStore(), fixtureModels: failed)
        }
    }

    private static func renderLearnedWords(to outDir: URL, log: inout [String]) {
        // Normal + search: real fixtures already seeded into replacements.json by seedFixtures().
        capture(name: "learned-words", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsLearnedWordsView()
        }
        capture(name: "learned-words-search", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsLearnedWordsView(initialSearch: "voice")
        }

        let erroring = LearnedWordsViewModel()
        erroring.load()
        erroring.saveError = "Couldn\u{2019}t save learned words. The disk is full."
        capture(name: "learned-words-save-error", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsLearnedWordsView(fixtureModel: erroring)
        }

        // Malformed: quarantine any existing fixture, write garbage, render, then restore.
        let url = VoicePopPaths.replacements
        let saved = try? Data(contentsOf: url)
        try? Data("{ this is not valid json".utf8).write(to: url)
        capture(name: "learned-words-malformed", to: outDir, size: NSSize(width: 520, height: 620), log: &log) {
            SettingsLearnedWordsView()
        }
        if let saved { try? saved.write(to: url) }
    }

    private static func renderCorrectionWindow(to outDir: URL, log: inout [String]) {
        let entry = HistoryEntry(
            ts: ISO8601DateFormatter().string(from: Date()), app: "Ghostty", style: "casual",
            raw: "send the report to sara by friday",
            rules: "Send the report to Sara by Friday.",
            out: "Send the report to Sara by Friday.", llm: false
        )
        CorrectionWindowController.shared.presentFixture(entry: entry, correctedText: entry.out)
        captureWindow(name: "correction-normal", window: CorrectionWindowController.shared.window, to: outDir, log: &log)

        CorrectionWindowController.shared.presentFixture(
            entry: entry, correctedText: "Send the report to Sarah by Friday.",
            errorMessage: "Couldn\u{2019}t save the correction. The disk is full."
        )
        captureWindow(name: "correction-error", window: CorrectionWindowController.shared.window, to: outDir, log: &log)
    }

    private static func renderSetupChecklist(to outDir: URL, log: inout [String]) {
        let fixture = SetupChecklist(
            engine: .done("Voxtype is installed."),
            model: .needsAction("The speech model isn\u{2019}t downloaded yet (about 2.4 GB, one time)."),
            evidence: .init(fnRecordingObserved: true, transcriptObserved: false, practiceInsertionObserved: false)
        )
        SetupChecklistWindowController.shared.model.loadFixtureForSnapshot(fixture)
        // Build the window without calling present() (which calls model.begin, probing the live
        // engine off-main). Reuse the controller's own window by calling present with a fixture
        // already loaded is unsafe (begin() would immediately overwrite it), so render the same
        // SwiftUI content directly instead.
        // The real window sizes itself with `host.view.fittingSize` (see SetupChecklistWindow.swift)
        // rather than a fixed size - match that here so the snapshot isn't an arbitrary crop.
        let probe = NSHostingController(rootView: SetupChecklistView(model: SetupChecklistWindowController.shared.model, close: {}))
        probe.view.layoutSubtreeIfNeeded()
        let fitting = probe.view.fittingSize
        capture(name: "setup-checklist", to: outDir, size: NSSize(width: max(480, fitting.width), height: max(420, fitting.height)), log: &log) {
            SetupChecklistView(model: SetupChecklistWindowController.shared.model, close: {})
        }
    }

    // MARK: - Menu / keyboard logging

    private static func logMenuStates(to outDir: URL, log: inout [String]) {
        let controller = StatusItemController()
        let scenarios: [(String, DaemonState, DictationStatus)] = [
            ("healthy", .idle, DictationStatus(daemon: .idle, facts: EngineFacts(modelInstalled: true))),
            ("recording", .recording, DictationStatus(daemon: .recording, facts: EngineFacts(modelInstalled: true))),
            ("engineNotRunning", .missing, DictationStatus(daemon: .missing, facts: EngineFacts())),
        ]
        log.append("== Menu states ==")
        for (name, state, status) in scenarios {
            let menu = controller.menuForSnapshot(state: state, status: status)
            log.append("-- \(name) --")
            for item in menu.items {
                if item.isSeparatorItem { log.append("   ---"); continue }
                // Log what NSMenuItemValidation actually returns, not the stored `isEnabled`
                // property - AppKit's autoenablesItems silently overrides the latter for any
                // targeted item, which is exactly what made N2-M1 invisible in earlier logs.
                let validated = item.target.flatMap { $0 as? NSMenuItemValidation }?.validateMenuItem(item) ?? item.isEnabled
                let flags = [
                    item.isHidden ? "hidden" : "visible",
                    validated ? "enabled" : "disabled",
                ].joined(separator: ", ")
                log.append("   \"\(item.title)\" [\(flags)]")
            }
        }
    }

    private static func logKeyboardNavigation(to outDir: URL, log: inout [String]) {
        log.append("== Key-view loop ==")
        let tabs: [(String, () -> NSView)] = [
            ("General", { NSHostingController(rootView: SettingsGeneralView(store: SettingsStore())).view }),
            ("Appearance", { NSHostingController(rootView: SettingsAppearanceView(store: SettingsStore())).view }),
            ("Dictation", { NSHostingController(rootView: SettingsDictationView(store: SettingsStore())).view }),
            ("LearnedWords", { NSHostingController(rootView: SettingsLearnedWordsView()).view }),
        ]
        for (name, makeView) in tabs {
            let view = makeView()
            let window = offscreenWindow(size: NSSize(width: 520, height: 620), content: view)
            window.makeFirstResponder(view)
            logKeyLoop(name: name, window: window, log: &log)
        }

        let entry = HistoryEntry(ts: "t", app: "Ghostty", style: "casual", raw: "r", rules: "r", out: "out", llm: false)
        CorrectionWindowController.shared.presentFixture(entry: entry, correctedText: "out")
        if let window = CorrectionWindowController.shared.window {
            logKeyLoop(name: "CorrectionWindow", window: window, log: &log)
        }
    }

    private static func logKeyLoop(name: String, window: NSWindow, log: inout [String]) {
        guard let content = window.contentView else { return }
        window.recalculateKeyViewLoop()
        var order: [String] = []
        var current: NSView? = content.nextValidKeyView ?? content
        var seen = Set<ObjectIdentifier>()
        var steps = 0
        while let view = current, steps < 40, !seen.contains(ObjectIdentifier(view)) {
            seen.insert(ObjectIdentifier(view))
            let label = view.accessibilityLabel() ?? String(describing: type(of: view))
            order.append(label)
            current = view.nextKeyView
            steps += 1
        }
        log.append("-- \(name): \(order.count) reachable, order: \(order.joined(separator: " -> "))")
    }

    // MARK: - Snapshot plumbing

    private static func capture<V: View>(name: String, to outDir: URL, size: NSSize, log: inout [String], @ViewBuilder view: () -> V) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let hosting = NSHostingController(rootView: view())
            let window = offscreenWindow(size: size, content: hosting.view)
            window.appearance = NSAppearance(named: appearance)
            hosting.view.layoutSubtreeIfNeeded()
            hosting.view.layoutSubtreeIfNeeded()
            writePNG(view: hosting.view, to: outDir.appendingPathComponent("\(name)-\(suffix).png"), log: &log)
        }
    }

    private static func captureWindow(name: String, window: NSWindow?, to outDir: URL, log: inout [String]) {
        guard let window, let content = window.contentView else {
            log.append("\(name): no window content to capture")
            return
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            writePNG(view: content, to: outDir.appendingPathComponent("\(name)-\(suffix).png"), log: &log)
        }
    }

    private static func offscreenWindow(size: NSSize, content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        content.frame = NSRect(origin: .zero, size: size)
        window.contentView = content
        return window
    }

    private static func writePNG(view: NSView, to url: URL, log: inout [String]) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            log.append("FAILED to allocate bitmap for \(url.lastPathComponent)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            log.append("FAILED to encode PNG for \(url.lastPathComponent)")
            return
        }
        do {
            try data.write(to: url)
            log.append("wrote \(url.lastPathComponent) (\(Int(view.bounds.width))x\(Int(view.bounds.height)))")
        } catch {
            log.append("FAILED to write \(url.lastPathComponent): \(error)")
        }
    }
}
