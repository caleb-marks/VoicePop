import Dispatch
import Foundation

public enum Style: String, Codable, CaseIterable, Sendable { case auto, casual, formal }

public enum Mascot: String, Codable, CaseIterable, Sendable { case popcorn, beagle }

public struct LLMPrefs: Codable, Equatable, Sendable {
    public var enabled = true
    public var model = "qwen3.5:4b-mlx"
    public var endpoint = "http://127.0.0.1:11434"
    public var timeoutMs = 3500

    public init(
        enabled: Bool = true,
        model: String = "qwen3.5:4b-mlx",
        endpoint: String = "http://127.0.0.1:11434",
        timeoutMs: Int = 3500
    ) {
        self.enabled = enabled
        self.model = model
        self.endpoint = endpoint
        self.timeoutMs = timeoutMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "qwen3.5:4b-mlx"
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? "http://127.0.0.1:11434"
        timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 3500
    }
}

public struct LearningPrefs: Codable, Equatable, Sendable {
    public var minCount = 1
    public var maxPhraseWords = 4

    public init(minCount: Int = 1, maxPhraseWords: Int = 4) {
        self.minCount = max(1, minCount)
        self.maxPhraseWords = max(1, min(8, maxPhraseWords))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minCount = max(1, try c.decodeIfPresent(Int.self, forKey: .minCount) ?? 1)
        maxPhraseWords = max(1, min(8, try c.decodeIfPresent(Int.self, forKey: .maxPhraseWords) ?? 4))
    }
}

public struct StylePrefs: Codable, Equatable, Sendable {
    public var version = 1
    public var global: Style = .auto
    public var perApp: [String: Style] = [:]
    public var llm = LLMPrefs()
    public var learning = LearningPrefs()
    public var mascot: Mascot = .popcorn
    public static let `default` = StylePrefs()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        if let raw = try c.decodeIfPresent(String.self, forKey: .global) {
            global = Style(rawValue: raw) ?? .auto
        } else {
            global = .auto
        }
        if let rawMap = try c.decodeIfPresent([String: String].self, forKey: .perApp) {
            var parsed: [String: Style] = [:]
            for (app, raw) in rawMap {
                if let style = Style(rawValue: raw) { parsed[app] = style }
            }
            perApp = parsed
        } else {
            perApp = [:]
        }
        llm = try c.decodeIfPresent(LLMPrefs.self, forKey: .llm) ?? LLMPrefs()
        learning = try c.decodeIfPresent(LearningPrefs.self, forKey: .learning) ?? LearningPrefs()
        if let raw = try c.decodeIfPresent(String.self, forKey: .mascot) {
            mascot = Mascot(rawValue: raw) ?? .popcorn
        } else {
            mascot = .popcorn
        }
    }

    public func resolve(app: String) -> Style {
        if let match = perApp.first(where: { $0.key.caseInsensitiveCompare(app) == .orderedSame }) {
            return match.value
        }
        return global
    }

    public static func load(from url: URL = VoicePopPaths.style) -> StylePrefs {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(StylePrefs.self, from: data)
        } catch {
            fputs("VoicePop: style.json decode failed, using defaults\n", stderr)
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            return .default
        }
    }

    public func save(to url: URL = VoicePopPaths.style) throws {
        try VoicePopPaths.ensureDir()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

public enum VoicePopPaths {
    public static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("voicepop")
    }
    public static var style: URL { dir.appendingPathComponent("style.json") }
    public static var history: URL { dir.appendingPathComponent("history.jsonl") }
    public static var historyRotated: URL { dir.appendingPathComponent("history.1.jsonl") }
    public static var corrections: URL { dir.appendingPathComponent("corrections.jsonl") }
    public static var replacements: URL { dir.appendingPathComponent("replacements.json") }

    public static func ensureDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Process-wide cache of `style.json`, so the HUD-appear path and the menu-open path never do a
/// synchronous file read on the main thread. `StatusItemController.savePrefs()` is the only writer
/// in this process tree, so `store(_:)` after a save keeps the cache authoritative; `refreshAsync()`
/// picks up hand edits to the file off-main for the *next* read.
///
/// The generation counter makes the refresh lose a race against a save rather than clobber it:
/// a background load only commits if nothing else wrote the cache while it was reading.
public enum StylePrefsCache {
    private static let lock = NSLock()
    private static var cached: StylePrefs?
    private static var generation: UInt64 = 0

    /// Cached prefs. Reads the file synchronously only on the very first call, which is
    /// `AppDelegate.applicationDidFinishLaunching` — at launch, not on any hot path.
    public static func current() -> StylePrefs {
        lock.lock()
        if let hit = cached {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let loaded = StylePrefs.load()
        lock.lock()
        if cached == nil {
            cached = loaded
            generation &+= 1
        }
        let out = cached ?? loaded
        lock.unlock()
        return out
    }

    /// Write-through after a successful save.
    public static func store(_ prefs: StylePrefs) {
        lock.lock()
        cached = prefs
        generation &+= 1
        lock.unlock()
    }

    /// Re-read `style.json` off the main thread; drop the result if the cache moved meanwhile.
    public static func refreshAsync() {
        lock.lock()
        let stamp = generation
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let loaded = StylePrefs.load()
            lock.lock()
            if generation == stamp {
                cached = loaded
                generation &+= 1
            }
            lock.unlock()
        }
    }
}
