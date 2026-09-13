import Darwin
import Foundation
import PopcornCore

final class OllamaWarmer {
    static let shared = OllamaWarmer()
    private let queue = DispatchQueue(label: "com.caleb.voicepop.ollama", qos: .utility)
    private var lastAttempt: Date?
    static let ollamaBin = "/opt/homebrew/bin/ollama"
    /// Private log (0600) instead of a world-readable, symlink-prone file in /tmp.
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoicePop/ollama.log")

    /// Call when Formal is (or becomes) the effective style. Never blocks the caller.
    func ensureWarm(_ llm: LLMPrefs) {
        guard llm.enabled else { return }
        queue.async { [self] in
            if let last = lastAttempt, Date().timeIntervalSince(last) < 60 { return }
            lastAttempt = Date()
            let client = OllamaClient(prefs: llm)
            if !client.isUp() {
                guard FileManager.default.isExecutableFile(atPath: Self.ollamaBin) else {
                    fputs("VoicePop: ollama not installed\n", stderr)
                    return
                }
                let log = Self.openLog()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Self.ollamaBin)
                process.arguments = ["serve"]
                process.standardOutput = log
                process.standardError = log
                process.standardInput = FileHandle.nullDevice
                try? process.run()
                for _ in 0..<20 {
                    if client.isUp() { break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            if client.isUp() { _ = client.warm() }
        }
    }

    private static func openLog() -> FileHandle? {
        let dir = logURL.deletingLastPathComponent().path
        guard mkdir(dir, 0o700) == 0 || errno == EEXIST else { return nil }
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        _ = fchmod(fd, 0o600)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func formalInEffect(_ prefs: StylePrefs) -> Bool {
        prefs.global == .formal || prefs.perApp.values.contains(.formal)
    }
}
