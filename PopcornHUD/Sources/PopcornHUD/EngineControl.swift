import AppKit
import Darwin
import PopcornCore

/// Voxtype daemon process control. Every entry point returns immediately; process work runs off
/// the main thread and completions are delivered on the main queue.
enum EngineControl {
    static let voxtypeBin = "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"
    static let voxtypeApp = "/Applications/Voxtype.app"
    private static let restartScriptDefaultsKey = "restartVoxtypeScript"
    private static var suppressTimer: DispatchSourceTimer?

    enum RecordCommand: String {
        case toggle, start, stop, cancel
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isEngineInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: voxtypeBin)
    }

    private static let processQueue = DispatchQueue(label: "com.caleb.voicepop.engine", qos: .userInitiated)
    /// Main thread. Completions waiting for the restart already in progress.
    private static var restartWaiters: [((Result<Void, Error>) -> Void)?]?

    /// Menu/Settings recording request. Fire-and-forget; state arrives through `StateWatcher`,
    /// so recording feedback appears only once the daemon actually records.
    static func record(_ command: RecordCommand) {
        Timing.event("record.request", ["cmd": command.rawValue])
        NotificationCenter.default.post(name: .voicePopRecordRequested, object: nil, userInfo: ["command": command.rawValue])
        processQueue.async {
            guard isEngineInstalled else { return }
            ProcessRunner.spawnDetached(voxtypeBin, ["record", command.rawValue])
        }
    }

    /// Starts the daemon at launch when nothing else did (reboot/logout). Checks run off main.
    static func startIfNotRunning() {
        processQueue.async {
            // A daemon without a readable PID file (other install, mid-restart) still counts:
            // starting another would make FN dictation type twice.
            guard !VoxtypeDaemon.isLive(), DaemonProcess.liveDaemonPIDs().isEmpty, isEngineInstalled else { return }
            fputs("VoicePop: Voxtype daemon not running at launch; starting it\n", stderr)
            DispatchQueue.main.async { restart() }
        }
    }

    /// Restarts the daemon without blocking the caller. Main thread. Calls made while a restart is
    /// in progress join it instead of killing the daemon again.
    static func restart(completion: ((Result<Void, Error>) -> Void)? = nil) {
        if restartWaiters != nil {
            restartWaiters?.append(completion)
            return
        }
        restartWaiters = [completion]
        Timing.event("engine.restart")
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                let waiters = restartWaiters ?? []
                restartWaiters = nil
                waiters.forEach { $0?(result) }
            }
        }
        processQueue.async {
            // Stop every live daemon first rather than relying on the script's `pkill -x voxtype-bin`,
            // which misses `voxtype` from Homebrew and would leave it running beside a new one.
            switch DaemonProcess.restartPlan(liveDaemons: DaemonProcess.liveDaemons(), bundlePath: voxtypeApp) {
            case .refuse(let path):
                Timing.event("engine.restart.refused")
                finish(.failure(Failure(message: "Voxtype is running from \(path). Restart it there, or quit it and use Restart again.")))
                return
            case .terminate(let pids):
                let survivors = DaemonProcess.terminate(pids)
                guard survivors.isEmpty else {
                    finish(.failure(Failure(message: "Voxtype didn’t quit, so it wasn’t restarted. Quit Voxtype, then use Restart again.")))
                    return
                }
            }
            if let script = restartScriptPath() {
                // The script sleeps and retries (~4 s); wait on this queue, never on main. A hung
                // script is killed so later restarts do not join it forever.
                finish(runAndWait(script, [], timeout: restartScriptTimeout))
                return
            }
            // Fallback: stop the daemon, reopen the app bundle (keeps its TCC identity), then
            // suppress the emoji tray.
            _ = runAndWait("/usr/bin/pkill", ["-x", "voxtype-bin"], timeout: 5)
            processQueue.asyncAfter(deadline: .now() + 1.0) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: voxtypeApp),
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { _, error in
                        DispatchQueue.main.async { scheduleMenubarSuppressRetries() }
                        finish(error.map { .failure($0) } ?? .success(()))
                    }
                }
            }
        }
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
        return nil
    }

    static let restartScriptTimeout: TimeInterval = 30

    /// Blocking; process queue only.
    private static func runAndWait(_ bin: String, _ args: [String], timeout: TimeInterval) -> Result<Void, Error> {
        let name = (bin as NSString).lastPathComponent
        do {
            let result = try ProcessRunner.run(bin, args, timeout: timeout, stdout: .discard, stderr: .discard)
            if result.timedOut { return .failure(Failure(message: "\(name) did not finish within \(Int(timeout)) s")) }
            return result.status == 0 ? .success(()) : .failure(Failure(message: "\(name) exited with status \(result.status)"))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Suppress Voxtype emoji tray

    /// Voxtype AppLaunch = daemon child + menubar parent. Kill parent only.
    static func suppressVoxtypeMenubar() {
        guard let result = try? ProcessRunner.run("/bin/ps", ["-axo", "pid=,args="], timeout: 5, stderr: .discard),
              result.succeeded
        else { return }
        let out = result.stdoutText

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

    /// Main-thread only.
    static func scheduleMenubarSuppressRetries() {
        suppressTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Voxtype may start after us; retry a few times then once more late.
        var remaining = 8
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
        timer.setEventHandler {
            suppressVoxtypeMenubar()
            remaining -= 1
            if remaining <= 0 {
                timer.cancel()
                DispatchQueue.main.async { if suppressTimer === timer { suppressTimer = nil } }
            }
        }
        suppressTimer = timer
        timer.resume()
    }

    static func cancelMenubarSuppressRetries() {
        suppressTimer?.cancel()
        suppressTimer = nil
    }
}
