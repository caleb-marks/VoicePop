import AppKit
import CoreFoundation
import Foundation
import PopcornCore

@main
enum VoxtypeCleanMain {
    static let iso8601 = ISO8601DateFormatter()

    static func main() {
        let started = Date()
        let deadline = started.addingTimeInterval(4.2)
        let original = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(data: original, encoding: .utf8) ?? String(decoding: original, as: UTF8.self)
        let app = frontmostApp()
        let env = ProcessInfo.processInfo.environment
        let prefs = StylePrefs.load()
        let style = env["VOICEPOP_STYLE"].flatMap(Style.init(rawValue:)) ?? prefs.resolve(app: app)
        let replacements = Replacements.load()
        // Automatic + terminal stays verbatim, including the glossary.
        let replaced = (style == .auto && TextClean.isTerminal(app))
            ? text
            : replacements.apply(to: text, minCount: prefs.learning.minCount)
        let rules = TextClean.clean(replaced, app: app, style: style)
        var out = rules
        var usedLLM = false
        // Even with explicit Formal, never rewrite shell commands.
        if style == .formal, prefs.llm.enabled, env["VOICEPOP_NO_LLM"] != "1", !TextClean.isTerminal(app), !rules.isEmpty {
            let remaining = Int(deadline.timeIntervalSinceNow * 1000)
            if remaining >= 300 {
                let client = OllamaClient(prefs: prefs.llm)
                if client.isUp(timeoutMs: min(300, remaining)) {
                    let budget = Int(deadline.timeIntervalSinceNow * 1000)
                    if budget >= 1000, let polished = client.polish(
                        text: rules,
                        glossary: replacements.glossary(limit: 30),
                        examples: CorrectionStore.recent(limit: 8),
                        budgetMs: budget
                    ) {
                        out = polished
                        usedLLM = true
                    }
                }
            }
        }
        let payload = out.isEmpty && !original.isEmpty ? original : Data(out.utf8)
        // The HUD's dismiss signal: fires before the daemon types the first character.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: VoicePopSignal.transcriptReady as CFString),
            nil,
            nil,
            true
        )
        FileHandle.standardOutput.write(payload)
        try? FileHandle.standardOutput.close()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HistoryStore.append(HistoryEntry(
                ts: VoxtypeCleanMain.iso8601.string(from: Date()),
                app: app,
                style: style.rawValue,
                raw: text,
                rules: rules,
                out: out,
                llm: usedLLM
            ))
        }
    }

    static func frontmostApp() -> String {
        if let override = ProcessInfo.processInfo.environment["VOXTYPE_CLEAN_APP"], !override.isEmpty {
            return override
        }
        return NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }
}
