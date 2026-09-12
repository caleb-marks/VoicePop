import AppKit
import Darwin
import PopcornCore

/// Voxtype daemon process control. Owned by the responsiveness/reliability workstream.
/// Every entry point returns immediately; process work runs off the main thread and
/// completions are delivered on the main queue.
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

    /// Menu/Settings recording request. Fire-and-forget; state arrives through `StateWatcher`.
    static func record(_ command: RecordCommand) {
        Timing.log("record request \(command.rawValue)")
        runDetached(voxtypeBin, ["record", command.rawValue])
    }

    /// Starts the daemon at launch when nothing else did (reboot/logout).
    static func startIfNotRunning() {
        guard !VoxtypeDaemon.isLive(), isEngineInstalled else { return }
        fputs("VoicePop: Voxtype daemon not running at launch; starting it\n", stderr)
        restart()
    }

    /// Restarts the daemon without blocking the caller.
    static func restart(completion: ((Result<Void, Error>) -> Void)? = nil) {
        if let script = restartScriptPath() {
            runDetached(script, [])
            completion.map { cb in DispatchQueue.main.async { cb(.success(())) } }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                // Fallback: kill all, reopen app bundle, then suppress emoji tray.
                let kill = Process()
                kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                kill.arguments = ["-x", "voxtype-bin"]
                try? kill.run()
                kill.waitUntilExit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: voxtypeApp),
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { _, error in
                        DispatchQueue.main.async {
                            scheduleMenubarSuppressRetries()
                            if let error { completion?(.failure(error)) } else { completion?(.success(())) }
                        }
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

    private static func runDetached(_ bin: String, _ args: [String]) {
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
