import AppKit
import Foundation

/// First-run installer so a downloaded VoicePop.app sets itself up like a normal Mac app.
/// Moves itself to /Applications, installs the bundled Parakeet-capable Voxtype build as
/// /Applications/Voxtype.app, downloads the speech model, writes a Voxtype config that routes
/// dictation through the bundled voxtype-clean, starts the daemon, and points the user at the
/// two System Settings switches macOS insists on. Does nothing on a machine already set up.
///
/// Env: VOICEPOP_SETUP_SKIP=1 bypasses everything (dev builds); VOICEPOP_SETUP_FORCE=1 runs the
/// flow even when nothing is missing; VOICEPOP_SETUP_AUTO=1 answers prompts without dialogs.
enum SetupAssistant {
    static let modelName = "parakeet-tdt-0.6b-v3-int8"
    static let voxtypeApp = "/Applications/Voxtype.app"
    static let installedApp = "/Applications/VoicePop.app"

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var skip: Bool { env["VOICEPOP_SETUP_SKIP"] == "1" }
    private static var force: Bool { env["VOICEPOP_SETUP_FORCE"] == "1" }
    private static var auto: Bool { env["VOICEPOP_SETUP_AUTO"] == "1" }

    private static var bundleURL: URL { Bundle.main.bundleURL }
    private static var isAppBundle: Bool { bundleURL.pathExtension == "app" }
    private static var bundledVoxtype: String { bundleURL.appendingPathComponent("Contents/Resources/voxtype-bin").path }
    private static var installedClean: String { (installedApp as NSString).appendingPathComponent("Contents/MacOS/voxtype-clean") }
    private static var configPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/voxtype/config.toml").path
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Calls `continueStartup` when the app should carry on. Does not call it when the app is
    /// relaunching itself from /Applications, or when setup failed.
    @MainActor static func runIfNeeded(then continueStartup: @escaping () -> Void) {
        guard isAppBundle, !skip else { continueStartup(); return }
        if relocateIfNeeded() { return }
        guard force || needsSetup() else { continueStartup(); return }

        let window = SetupWindow()
        window.show()
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try perform { message, fraction in
                    fputs("VoicePop setup: \(message)\n", stderr)
                    DispatchQueue.main.async { window.update(message: message, fraction: fraction) }
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                window.dismiss()
                finish(failure: failure)
                if failure == nil { continueStartup() }
            }
        }
    }

    // MARK: - Decide

    private static func needsSetup() -> Bool {
        if !isParakeetCapable(VoxtypeModel.bin) { return true }
        if !FileManager.default.fileExists(atPath: configPath) { return true }
        return !VoxtypeModel.installedNames().contains(modelName)
    }

    private static func isParakeetCapable(_ bin: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: bin),
              let out = try? run(bin, ["info", "engines"]) else { return false }
        return out.contains("compiled  parakeet")
    }

    // MARK: - Move to /Applications

    /// Returns true when a relaunch from /Applications has been started.
    @MainActor private static func relocateIfNeeded() -> Bool {
        let path = bundleURL.path
        if path.hasPrefix("/Applications/") { return false }
        let mustMove = force || needsSetup()
        if !auto {
            let alert = NSAlert()
            alert.messageText = "Move VoicePop to the Applications folder?"
            alert.informativeText = "VoicePop runs from Applications so it can start at login and keep its permissions."
            alert.addButton(withTitle: "Move to Applications")
            if !mustMove { alert.addButton(withTitle: "Not Now") }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        do {
            quitOtherInstances()
            let fm = FileManager.default
            if fm.fileExists(atPath: installedApp) { try fm.removeItem(atPath: installedApp) }
            try fm.copyItem(atPath: path, toPath: installedApp)
            try clearQuarantine(installedApp)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", installedApp]
            try open.run()
            open.waitUntilExit()
            guard open.terminationStatus == 0 else {
                throw Failure(message: "Could not open VoicePop in Applications.")
            }
            guard waitForInstalledInstance(timeout: 5) else {
                throw Failure(message: "VoicePop did not start from Applications.")
            }
            fputs("VoicePop setup: moved to \(installedApp), relaunching\n", stderr)
            NSApp.terminate(nil)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not move VoicePop to Applications"
            alert.informativeText = "\(error.localizedDescription)\n\nDrag VoicePop.app into Applications yourself, then open it again."
            alert.runModal()
            return false
        }
    }

    @MainActor private static func waitForInstalledInstance(timeout: TimeInterval) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = NSRunningApplication.runningApplications(withBundleIdentifier: PopcornHUDMain.bundleID)
                .contains {
                    $0.processIdentifier != me
                        && ($0.bundleURL?.path.hasPrefix("/Applications/") ?? false)
                }
            if found { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor private static func quitOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: PopcornHUDMain.bundleID)
            .filter { $0.processIdentifier != me }
        for app in others { app.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in others where !app.isTerminated { app.forceTerminate() }
    }

    // MARK: - Steps

    private static func perform(report: @escaping (String, Double?) -> Void) throws {
        guard bundleURL.path.hasPrefix("/Applications/") else {
            throw Failure(message: "Move VoicePop to Applications first, then open it again.")
        }
        let fm = FileManager.default

        if !isParakeetCapable(VoxtypeModel.bin) {
            report("Installing the Voxtype speech engine…", nil)
            guard fm.isExecutableFile(atPath: bundledVoxtype) else {
                throw Failure(message: "This copy of VoicePop has no bundled Voxtype engine. Install Voxtype from https://voxtype.io and open VoicePop again.")
            }
            try clearQuarantine(bundledVoxtype)
            _ = try run(bundledVoxtype, ["setup", "app-bundle"])
            try clearQuarantine(voxtypeApp)
            guard isParakeetCapable(VoxtypeModel.bin) else {
                throw Failure(message: "Voxtype did not install to \(voxtypeApp).")
            }
        }

        if !fm.fileExists(atPath: configPath) {
            report("Writing dictation settings…", nil)
            guard let template = Bundle.main.url(forResource: "config", withExtension: "toml"),
                  var text = try? String(contentsOf: template, encoding: .utf8) else {
                throw Failure(message: "The settings template is missing from this copy of VoicePop.")
            }
            text = text.replacingOccurrences(of: "__VOICEPOP_ROOT__/bin/voxtype-clean", with: installedClean)
            try fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: configPath, atomically: true, encoding: .utf8)
        }

        if !VoxtypeModel.installedNames().contains(modelName) {
            report("Downloading the speech model (about 2.4 GB, one time)…", 0)
            try downloadModel(report: report)
        }

        report("Starting dictation…", nil)
        try startDaemon()
    }

    private static func startDaemon() throws {
        if let script = Bundle.main.url(forResource: "restart-voxtype", withExtension: "sh")?.path {
            do {
                _ = try run(script, [])
                return
            } catch {
                fputs("VoicePop setup: restart-voxtype failed (\(error.localizedDescription)); opening Voxtype.app\n", stderr)
            }
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: voxtypeApp),
                configuration: NSWorkspace.OpenConfiguration()
            )
            group.leave()
        }
        group.wait()
    }

    private static func downloadModel(report: @escaping (String, Double?) -> Void) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: VoxtypeModel.bin)
        task.arguments = ["setup", "--download", "--activate", "--model", modelName, "--progress-format", "json", "--quiet"]
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        let buffer = LineBuffer()
        let notes = DownloadNotes()
        func consume(_ lines: [Data]) {
            for line in lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let event = obj["event"] as? String else { continue }
                if event == "error" {
                    let msg = (obj["message"] as? String)
                        ?? (obj["error"] as? String)
                        ?? "Model download failed."
                    notes.setError(msg)
                    continue
                }
                guard event == "progress", let pct = obj["pct"] as? Double else { continue }
                let bytes = (obj["bytes"] as? Double ?? 0) / 1_073_741_824
                let total = (obj["total"] as? Double ?? 0) / 1_073_741_824
                report(String(format: "Downloading the speech model… %.1f of %.1f GB", bytes, total), pct / 100)
            }
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            consume(buffer.append(handle.availableData))
        }
        let stderrBuffer = LineBuffer()
        err.fileHandleForReading.readabilityHandler = { _ = stderrBuffer.append($0.availableData) }
        try task.run()
        task.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        consume(buffer.append(out.fileHandleForReading.readDataToEndOfFile()))
        _ = stderrBuffer.append(err.fileHandleForReading.readDataToEndOfFile())
        if let detail = notes.error?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            throw Failure(message: detail)
        }
        guard task.terminationStatus == 0 else {
            let detail = stderrBuffer.allText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "Model download failed." : detail)
        }
    }

    // MARK: - Finish

    @MainActor private static func finish(failure: String?) {
        if let failure {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "VoicePop setup did not finish"
            alert.informativeText = failure
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        guard !auto else { return }
        NSApp.activate(ignoringOtherApps: true)
        let privacy = NSAlert()
        privacy.messageText = "One more step: allow Voxtype to type for you"
        privacy.informativeText = "In System Settings → Privacy & Security, turn on Voxtype under Accessibility and Input Monitoring. Microphone asks on its own the first time you record.\n\nGrant these to Voxtype, not VoicePop."
        privacy.addButton(withTitle: "Open Privacy & Security")
        privacy.addButton(withTitle: "Later")
        if privacy.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        let keyboard = NSAlert()
        keyboard.messageText = "Free up the 🌐 key"
        keyboard.informativeText = "In System Settings → Keyboard, set “Press 🌐 key to” to Do Nothing. Then hold FN, talk, and release to type."
        keyboard.addButton(withTitle: "Open Keyboard Settings")
        keyboard.addButton(withTitle: "Done")
        if keyboard.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    private static func clearQuarantine(_ path: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        // xattr -d exits non-zero when the attribute is already absent; that is not a failure.
        guard !hasQuarantine(path) else {
            throw Failure(message: "Could not clear quarantine on \((path as NSString).lastPathComponent).")
        }
    }

    private static func hasQuarantine(_ path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-p", "com.apple.quarantine", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    @discardableResult
    private static func run(_ bin: String, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = args
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        let group = DispatchGroup()
        var stderr = ""
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            group.leave()
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        group.wait()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "\((bin as NSString).lastPathComponent) \(args.joined(separator: " ")) failed (\(task.terminationStatus))" : detail)
        }
        return stdout
    }
}

/// Small floating progress panel shown while setup runs.
@MainActor
private final class SetupWindow {
    private let window: NSWindow
    private let title = NSTextField(labelWithString: "Setting up VoicePop")
    private let message = NSTextField(labelWithString: "Checking what is installed…")
    private let bar = NSProgressIndicator()

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 130),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "VoicePop"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        title.font = .boldSystemFont(ofSize: 15)
        title.frame = NSRect(x: 24, y: 88, width: 392, height: 22)
        message.font = .systemFont(ofSize: 13)
        message.lineBreakMode = .byTruncatingTail
        message.frame = NSRect(x: 24, y: 58, width: 392, height: 20)
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = NSRect(x: 24, y: 26, width: 392, height: 20)
        content.addSubview(title)
        content.addSubview(message)
        content.addSubview(bar)
        window.contentView = content
    }

    func show() {
        window.center()
        bar.startAnimation(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(message text: String, fraction: Double?) {
        message.stringValue = text
        if let fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    func dismiss() {
        bar.stopAnimation(nil)
        window.orderOut(nil)
    }
}

/// Thread-safe byte accumulator that hands back complete lines.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var all = Data()

    /// Appends bytes and returns every complete line received so far.
    func append(_ chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        all.append(chunk)
        data.append(chunk)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(Data(data[data.startIndex..<nl]))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var allText: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: all, encoding: .utf8) ?? ""
    }
}

/// Thread-safe slot for a download-progress JSON error event.
private final class DownloadNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func setError(_ message: String) {
        lock.lock(); stored = message; lock.unlock()
    }

    var error: String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
