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

    /// Whether the model Voxtype is configured to load is on disk, so a user who switched to a
    /// Whisper model in Settings is not sent back through setup. Falls back to the default Parakeet
    /// model (or a packaged variant of it) when the configured model can't be determined.
    static func modelInstalled() -> Bool {
        if let configured = EngineProbe.probe().modelInstalled { return configured }
        return ModelIdentity.isInstalled(modelName, in: VoxtypeModel.installedNames())
    }

    /// The model setup should download: whatever model Voxtype is configured to load (downloaded
    /// without changing the selection), or the default Parakeet model, activated, when nothing
    /// usable is configured.
    static func modelToInstall() -> (name: String, activate: Bool) {
        guard let configured = EngineProbe.probe().configuredModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configured.isEmpty, !configured.hasPrefix("/")
        else { return (modelName, true) }
        // Keep the user's choice, including engine model names VoicePop's catalog doesn't list.
        let name = VoxtypeModel.catalog.first(where: { ModelIdentity.same($0.id, configured) })?.id ?? configured
        return (name, false)
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
                            // `AppInstaller` messages already say what state Applications was
                            // left in and what to do next.
                            let alert = NSAlert()
                            alert.messageText = "Could not install VoicePop in Applications"
                            alert.informativeText = "\(error.localizedDescription)\n\nIf this keeps happening, drag VoicePop.app into Applications yourself, then open it again."
                            alert.runModal()
                            done(false)
                        }
                    }
                }
            }
        }
    }

    /// Where the copy an upgrade replaced is kept (newest only), so a bad update is recoverable
    /// by dragging it back into Applications. Outside /Applications so Launch Services never
    /// picks it over the installed copy.
    static var previousVersionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoicePop/Previous Versions", isDirectory: true)
    }

    /// Off the main thread. Stage → verify → swap → launch through `AppInstaller`, so the copy
    /// already in /Applications is never deleted before its replacement is known to be complete,
    /// and is put back if the new one fails to start (see `AppInstaller` for each failure path).
    private static func moveAndRelaunch(from path: String) throws {
        quitOtherInstances()
        let installer = AppInstaller(
            verify: { try verifyStagedApp(at: $0) },
            launch: { url in
                _ = try run("/usr/bin/open", ["-n", url.path])
                guard waitForInstalledInstance(timeout: 5) else {
                    throw Failure(message: "no VoicePop process appeared within 5 seconds")
                }
            }
        )
        let outcome = try installer.install(
            source: URL(fileURLWithPath: path),
            destination: URL(fileURLWithPath: installedApp),
            backupDirectory: previousVersionsDirectory
        )
        if let backup = outcome.previousBackup {
            fputs("VoicePop setup: previous copy kept at \(backup.path)\n", stderr)
        }
    }

    /// A staged copy must be a complete, correctly signed VoicePop before it replaces anything.
    private static func verifyStagedApp(at url: URL) throws {
        let executable = url.appendingPathComponent("Contents/MacOS/VoicePop").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure(message: "the app bundle is incomplete (its main executable is missing)")
        }
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == PopcornHUDMain.bundleID else {
            throw Failure(message: "the app bundle is not VoicePop")
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
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

    static func downloadModel(_ name: String, activate: Bool, report: @escaping (String, Double?) -> Void) throws {
        let failure = LockedMessage()
        let result = try ProcessRunner.run(
            VoxtypeModel.bin,
            ["setup", "--download"] + (activate ? ["--activate"] : []) + ["--model", name, "--progress-format", "json", "--quiet"],
            stdout: .discard,
            onStdoutLine: { line in
                switch ModelDownloadProgress.parse(line: line) {
                case .progress(let fraction, let bytesGB, let totalGB)?:
                    report(String(format: "Downloading the speech model… %.1f of %.1f GB", bytesGB, totalGB), fraction)
                case .failure(let message)?:
                    failure.set(message)
                case nil:
                    break
                }
            }
        )
        if let detail = failure.value?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            throw Failure(message: detail)
        }
        guard result.succeeded else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "Model download failed." : detail)
        }
    }

    // MARK: - Helpers

    /// Short, bounded helper commands (`info engines`, `codesign --verify`, `open`).
    @discardableResult
    private static func run(_ bin: String, _ args: [String], timeout: TimeInterval = 60) throws -> String {
        let result = try ProcessRunner.run(bin, args, timeout: timeout)
        guard result.succeeded else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (bin as NSString).lastPathComponent
            if result.timedOut { throw Failure(message: "\(name) \(args.joined(separator: " ")) timed out.") }
            throw Failure(message: detail.isEmpty ? "\(name) \(args.joined(separator: " ")) failed (\(result.status))" : detail)
        }
        return result.stdoutText
    }
}

/// Thread-safe slot for a download-progress JSON error event.
private final class LockedMessage: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func set(_ message: String) {
        lock.lock(); stored = message; lock.unlock()
    }

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
