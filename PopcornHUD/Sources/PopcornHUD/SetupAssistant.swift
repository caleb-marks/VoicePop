import AppKit
import Foundation
import PopcornCore

/// First-run installer and recovery checklist, so a downloaded VoicePop.app sets itself up like a
/// normal Mac app. Moves itself to /Applications, installs the bundled Parakeet-capable Voxtype
/// build as /Applications/Voxtype.app, writes a Voxtype config that routes dictation through the
/// bundled voxtype-clean, downloads the speech model, then guides the macOS permissions, the
/// FN/Globe key, and a practice dictation in one checklist window (`SetupChecklistWindow`).
///
/// All process and file work runs off the main thread. Engine/model state is always re-probed;
/// permission, FN, and practice steps complete only on functional evidence.
///
/// Env: VOICEPOP_SETUP_SKIP=1 bypasses everything (dev builds); VOICEPOP_SETUP_FORCE=1 opens the
/// checklist even when nothing is missing; VOICEPOP_SETUP_AUTO=1 answers prompts without dialogs.
enum SetupAssistant {
    static let modelName = "parakeet-tdt-0.6b-v3-int8"
    static let voxtypeApp = "/Applications/Voxtype.app"
    static let installedApp = "/Applications/VoicePop.app"

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var skip: Bool { env["VOICEPOP_SETUP_SKIP"] == "1" }
    private static var force: Bool { env["VOICEPOP_SETUP_FORCE"] == "1" }
    static var auto: Bool { env["VOICEPOP_SETUP_AUTO"] == "1" }

    private static var bundleURL: URL { Bundle.main.bundleURL }
    private static var isAppBundle: Bool { bundleURL.pathExtension == "app" }
    private static var bundledHelper: String { bundleURL.appendingPathComponent("Contents/Helpers/Voxtype.app").path }
    private static var bundledVoxtype: String { (bundledHelper as NSString).appendingPathComponent("Contents/MacOS/voxtype-bin") }
    private static var installedClean: String { (installedApp as NSString).appendingPathComponent("Contents/MacOS/voxtype-clean") }
    private static var configPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/voxtype/config.toml").path
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Calls `continueStartup` once the engine and model are ready. Does not call it while the app
    /// is relaunching itself from /Applications. When something is missing, the checklist window
    /// installs it with progress and retry, and calls `continueStartup` when that work succeeds.
    static func runIfNeeded(then continueStartup: @escaping () -> Void) {
        guard isAppBundle, !skip else { continueStartup(); return }
        relocateIfNeeded { relaunching in
            if relaunching { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let needed = force || needsSetup()
                DispatchQueue.main.async {
                    if needed {
                        SetupChecklistWindowController.shared.present(install: true, onServicesReady: continueStartup)
                    } else {
                        continueStartup()
                    }
                }
            }
        }
    }

    /// Opens the setup/recovery checklist from Settings or a recovery action. Safe to call while
    /// dictation services are already running; never starts a second HUD or daemon.
    static func presentChecklist() {
        SetupChecklistWindowController.shared.present(install: false, onServicesReady: nil)
    }

    // MARK: - Probes (call off the main thread)

    static func needsSetup() -> Bool {
        !engineReady() || !configPresent() || !modelInstalled()
    }

    static func engineReady() -> Bool {
        isParakeetCapable(VoxtypeModel.bin)
    }

    static func configPresent() -> Bool {
        FileManager.default.fileExists(atPath: configPath)
    }

    /// The engine may report a packaged variant (e.g. `…-int8-prepacked`) of the default model.
    static func modelInstalled() -> Bool {
        ModelIdentity.isInstalled(modelName, in: VoxtypeModel.installedNames())
    }

    private static func isParakeetCapable(_ bin: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: bin),
              let out = try? run(bin, ["info", "engines"]) else { return false }
        return out.contains("compiled  parakeet")
    }

    // MARK: - Move to /Applications

    /// Calls `done(true)` when a relaunch from /Applications has been started.
    private static func relocateIfNeeded(_ done: @escaping (Bool) -> Void) {
        let path = bundleURL.path
        if path.hasPrefix("/Applications/") { done(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let mustMove = force || needsSetup()
            DispatchQueue.main.async {
                if !auto {
                    let alert = NSAlert()
                    alert.messageText = "Move VoicePop to the Applications folder?"
                    alert.informativeText = "VoicePop runs from Applications so it can start at login and keep its permissions."
                    alert.addButton(withTitle: "Move to Applications")
                    if !mustMove { alert.addButton(withTitle: "Not Now") }
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() != .alertFirstButtonReturn { done(false); return }
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try moveAndRelaunch(from: path)
                        DispatchQueue.main.async {
                            fputs("VoicePop setup: moved to \(installedApp), relaunching\n", stderr)
                            done(true)
                            NSApp.terminate(nil)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "Could not move VoicePop to Applications"
                            alert.informativeText = "\(error.localizedDescription)\n\nDrag VoicePop.app into Applications yourself, then open it again."
                            alert.runModal()
                            done(false)
                        }
                    }
                }
            }
        }
    }

    /// Off the main thread.
    private static func moveAndRelaunch(from path: String) throws {
        quitOtherInstances()
        let fm = FileManager.default
        if fm.fileExists(atPath: installedApp) { try fm.removeItem(atPath: installedApp) }
        try fm.copyItem(atPath: path, toPath: installedApp)
        _ = try run("/usr/bin/open", ["-n", installedApp])
        guard waitForInstalledInstance(timeout: 5) else {
            throw Failure(message: "VoicePop did not start from Applications.")
        }
    }

    private static func waitForInstalledInstance(timeout: TimeInterval) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = NSRunningApplication.runningApplications(withBundleIdentifier: PopcornHUDMain.bundleID)
                .contains {
                    $0.processIdentifier != me
                        && ($0.bundleURL?.path.hasPrefix("/Applications/") ?? false)
                }
            if found { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func quitOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: PopcornHUDMain.bundleID)
            .filter { $0.processIdentifier != me }
        for app in others { app.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for app in others where !app.isTerminated { app.forceTerminate() }
    }

    // MARK: - Steps (call off the main thread)

    static func installEngine(report: @escaping (String, Double?) -> Void) throws {
        guard !engineReady() else { return }
        guard bundleURL.path.hasPrefix("/Applications/") else {
            throw Failure(message: "Move VoicePop to Applications first, then open it again.")
        }
        let fm = FileManager.default
        report("Installing the Voxtype speech engine…", nil)
        guard fm.isExecutableFile(atPath: bundledVoxtype) else {
            throw Failure(message: "This copy of VoicePop has no bundled Voxtype engine. Install Voxtype from https://voxtype.io, then choose Try Again.")
        }
        // Copy the pre-signed helper intact; rebuilding its bundle breaks its signature.
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundledHelper])
        if fm.fileExists(atPath: voxtypeApp) {
            throw Failure(message: "An incompatible Voxtype app is already in Applications. Move it to the Trash, then choose Try Again.")
        }
        try fm.copyItem(atPath: bundledHelper, toPath: voxtypeApp)
        guard engineReady() else {
            throw Failure(message: "Voxtype did not install to \(voxtypeApp).")
        }
    }

    static func writeConfigIfMissing() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configPath) else { return }
        guard let template = Bundle.main.url(forResource: "config", withExtension: "toml"),
              var text = try? String(contentsOf: template, encoding: .utf8) else {
            throw Failure(message: "The settings template is missing from this copy of VoicePop.")
        }
        text = text.replacingOccurrences(of: "__VOICEPOP_ROOT__/bin/voxtype-clean", with: installedClean)
        try fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    static func downloadModel(report: @escaping (String, Double?) -> Void) throws {
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

    // MARK: - Helpers

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
