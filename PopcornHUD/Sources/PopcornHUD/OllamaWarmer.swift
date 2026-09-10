import Foundation
import PopcornCore

final class OllamaWarmer {
    static let shared = OllamaWarmer()
    private let queue = DispatchQueue(label: "com.caleb.voicepop.ollama", qos: .utility)
    private var lastAttempt: Date?
    static let ollamaBin = "/opt/homebrew/bin/ollama"
    static let logPath = "/tmp/voicepop-ollama.log"

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
                if !FileManager.default.fileExists(atPath: Self.logPath) {
                    FileManager.default.createFile(atPath: Self.logPath, contents: nil)
                }
                let log = FileHandle(forWritingAtPath: Self.logPath)
                _ = try? log?.seekToEnd()
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

    static func formalInEffect(_ prefs: StylePrefs) -> Bool {
        prefs.global == .formal || prefs.perApp.values.contains(.formal)
    }
}
