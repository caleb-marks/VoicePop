import Dispatch
import Foundation

/// Minimal untyped JSON value, used only to round-trip fields this app does not understand
/// (forward/backward compatibility with hand-edited or future config files).
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// Shared "round-trip unknown JSON fields" plumbing, used by `StylePrefs`, `Replacements`, and
/// `Replacement` so hand edits or a newer app version's fields survive a save from here instead
/// of being silently dropped. Previously copied three times with a private `ExtraKey` in each.
public enum UnknownFieldCapture {
    struct ExtraKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// Everything in the decoder's top-level object except `knownKeys`.
    public static func extra(from decoder: Decoder, knownKeys: [String]) -> [String: JSONValue] {
        guard let raw = try? decoder.singleValueContainer(),
              let all = try? raw.decode([String: JSONValue].self)
        else { return [:] }
        var extra = all
        for key in knownKeys { extra.removeValue(forKey: key) }
        return extra
    }

    /// Encodes `fields` as additional top-level keys alongside whatever the caller already wrote
    /// through its own `CodingKeys` container.
    public static func encode(_ fields: [String: JSONValue], to encoder: Encoder) throws {
        guard !fields.isEmpty else { return }
        var extra = encoder.container(keyedBy: ExtraKey.self)
        for (key, value) in fields {
            guard let codingKey = ExtraKey(stringValue: key) else { continue }
            try extra.encode(value, forKey: codingKey)
        }
    }
}

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
    /// Top-level keys this version of the app does not recognize. Round-tripped so hand edits or
    /// a newer app version's fields survive a save from here instead of being dropped.
    public var unknownFields: [String: JSONValue] = [:]
    public static let `default` = StylePrefs()

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, global, perApp, llm, learning, mascot
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unknownFields = UnknownFieldCapture.extra(from: decoder, knownKeys: CodingKeys.allCases.map(\.stringValue))
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

    /// Custom encode so unknown fields captured at load round-trip back to the file instead of
    /// being dropped, while known fields stay in their normal shape.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(global.rawValue, forKey: .global)
        try c.encode(perApp.mapValues(\.rawValue), forKey: .perApp)
        try c.encode(llm, forKey: .llm)
        try c.encode(learning, forKey: .learning)
        try c.encode(mascot.rawValue, forKey: .mascot)
        try UnknownFieldCapture.encode(unknownFields, to: encoder)
    }

    public func resolve(app: String) -> Style {
        if let match = perApp.first(where: { $0.key.caseInsensitiveCompare(app) == .orderedSame }) {
            return match.value
        }
        return global
    }

    public static func load(from url: URL = VoicePopPaths.style) -> StylePrefs {
        try? VoicePopPaths.ensureDir()
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(StylePrefs.self, from: data)
        } catch {
            fputs("VoicePop: style.json decode failed, using defaults\n", stderr)
            try? VoicePopPaths.quarantine(url)
            return .default
        }
    }

    public func save(to url: URL = VoicePopPaths.style) throws {
        try VoicePopPaths.ensureDir()
        try VoicePopPaths.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        try VoicePopPaths.secureFile(url)
    }
}

public enum VoicePopPaths {
    /// `VOICEPOP_CONFIG_DIR` overrides the config directory for fixtures and tests (harness use
    /// only - never point this at live user data). Read fresh each call so tests can flip it
    /// between cases without process restart.
    public static var dir: URL {
        if let override = ProcessInfo.processInfo.environment["VOICEPOP_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("voicepop")
    }
    public static var style: URL { dir.appendingPathComponent("style.json") }
    public static var history: URL { dir.appendingPathComponent("history.jsonl") }
    public static var historyRotated: URL { dir.appendingPathComponent("history.1.jsonl") }
    public static var corrections: URL { dir.appendingPathComponent("corrections.jsonl") }
    public static var replacements: URL { dir.appendingPathComponent("replacements.json") }

    // Timestamped .bad-<time> quarantine files (see `quarantine`) are secured individually at
    // quarantine time, not through this fixed list.
    static var privateFiles: [URL] {
        [style, history, historyRotated, corrections, replacements]
    }

    public static func ensureDir() throws {
        try ensurePrivateDirectory(at: dir)
        for file in privateFiles where FileManager.default.fileExists(atPath: file.path) {
            try secureFile(file)
        }
    }

    /// Chmods to 0700 only when VoicePop is the one creating the directory (L-17): before this,
    /// every call re-chmodded whatever `url` already pointed at, so a `VOICEPOP_CONFIG_DIR`
    /// override aimed at an existing shared directory (e.g. `$HOME`, a project folder) had its
    /// permissions silently changed. An existing directory is left exactly as it was.
    public static func ensurePrivateDirectory(at url: URL) throws {
        let existedBefore = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard !existedBefore else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func secureFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Moves a corrupt/malformed file aside instead of overwriting it - the one quarantine
    /// implementation (L-13; previously `StylePrefs.load`, `CorrectionSaver.quarantine`, and
    /// `LearnedWordsViewModel.quarantineAndStartFresh` each had their own, with inconsistent error
    /// handling). The `.bad-<unix time>` suffix means a second corruption never destroys an
    /// earlier quarantined copy the way a fixed `.bad` name would. Throws (rather than silently
    /// claiming success) if the move itself fails, e.g. on permissions.
    public static func quarantine(_ url: URL, now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bad = url.appendingPathExtension("bad-\(Int(now.timeIntervalSince1970))")
        try FileManager.default.moveItem(at: url, to: bad)
        try? secureFile(bad)
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
    /// `AppDelegate.applicationDidFinishLaunching` - at launch, not on any hot path.
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
