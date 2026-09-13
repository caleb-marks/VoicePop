import Foundation

public struct HistoryEntry: Codable, Equatable {
    public var ts: String
    public var app: String
    public var style: String
    public var raw: String
    public var rules: String
    public var out: String
    public var llm: Bool

    public init(ts: String, app: String, style: String, raw: String, rules: String, out: String, llm: Bool) {
        self.ts = ts
        self.app = app
        self.style = style
        self.raw = raw
        self.rules = rules
        self.out = out
        self.llm = llm
    }
}

enum AppendError: Error {
    case openFailed(Int32)
    case writeFailed(Int32)
}

/// One `write(2)` loop, EINTR-safe. Replaces the FileHandle open/seek/write dance, which
/// costs ~2.0 ms per dictation inside the window the daemon blocks on.
func appendAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var off = 0
        while off < raw.count {
            let n = write(fd, base.advanced(by: off), raw.count - off)
            if n < 0 {
                if errno == EINTR { continue }
                throw AppendError.writeFailed(errno)
            }
            off += n
        }
    }
}

public enum HistoryStore {
    public static func append(
        _ e: HistoryEntry,
        to url: URL = VoicePopPaths.history,
        rotated: URL = VoicePopPaths.historyRotated
    ) {
        do {
            try VoicePopPaths.ensureDir()
            try VoicePopPaths.ensurePrivateDirectory(at: url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(e) + Data("\n".utf8)
            var fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else { throw AppendError.openFailed(errno) }
            if fchmod(fd, 0o600) != 0 {
                let code = errno
                close(fd)
                throw AppendError.writeFailed(code)
            }
            var st = stat()
            if fstat(fd, &st) == 0, st.st_size > 1_048_576 {
                close(fd)
                if FileManager.default.fileExists(atPath: rotated.path) {
                    try FileManager.default.removeItem(at: rotated)
                }
                try FileManager.default.moveItem(at: url, to: rotated)
                try VoicePopPaths.secureFile(rotated)
                fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
                guard fd >= 0 else { throw AppendError.openFailed(errno) }
                if fchmod(fd, 0o600) != 0 {
                    let code = errno
                    close(fd)
                    throw AppendError.writeFailed(code)
                }
            }
            defer { close(fd) }
            try appendAll(fd: fd, data: data)
        } catch {
            fputs("VoicePop: history append failed: \(error)\n", stderr)
        }
    }

    public static func last(from url: URL = VoicePopPaths.history) -> HistoryEntry? {
        try? VoicePopPaths.ensureDir()
        guard let line = TailReader.tailLines(of: url).last(where: { !$0.isEmpty }) else {
            return nil
        }
        return try? JSONDecoder().decode(HistoryEntry.self, from: Data(line.utf8))
    }

    public static func clear(
        active: URL = VoicePopPaths.history,
        rotated: URL = VoicePopPaths.historyRotated
    ) throws {
        for url in [active, rotated] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Process-wide cache of `HistoryStore.last()`, so the menu (opened often, and on every idle
/// transition) and "Fix Last Dictation"/"Copy Last Text" never do a synchronous `history.jsonl`
/// tail-read on the main thread. Mirrors `StylePrefsCache`'s generation-guarded refresh pattern.
public enum LastHistoryEntryCache {
    private static let lock = NSLock()
    private static var cached: HistoryEntry?
    private static var loaded = false
    private static var generation: UInt64 = 0

    /// Cached value only - never touches disk. `nil` both "no dictation yet" and "not loaded
    /// yet"; callers that must tell those apart use `currentAsync`.
    public static func current() -> HistoryEntry? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Delivers the cached value on the main queue immediately if it has been loaded at least
    /// once; otherwise loads off-main first. Use for a one-off action (Copy Last Text) where the
    /// cache might still be cold (e.g. right after launch).
    public static func currentAsync(completion: @escaping (HistoryEntry?) -> Void) {
        lock.lock()
        let isLoaded = loaded
        let value = cached
        lock.unlock()
        if isLoaded {
            DispatchQueue.main.async { completion(value) }
        } else {
            refreshAsync(completion: completion)
        }
    }

    /// Re-reads `history.jsonl` off the main thread and updates the cache; safe to call often
    /// (idle transitions, a transcript-ready signal). `completion`, if given, always runs on main.
    public static func refreshAsync(completion: ((HistoryEntry?) -> Void)? = nil) {
        lock.lock()
        generation &+= 1
        let stamp = generation
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let value = HistoryStore.last()
            lock.lock()
            if generation == stamp {
                cached = value
                loaded = true
            }
            let result = cached
            lock.unlock()
            if let completion { DispatchQueue.main.async { completion(result) } }
        }
    }

    /// Synchronously marks the cache empty-and-loaded. Call right after `HistoryStore.clear()`
    /// succeeds (L-3): the caller already knows for a fact there is nothing left, so this is pure
    /// bookkeeping, not a disk read, and is safe on the main thread.
    public static func clear() {
        lock.lock()
        generation &+= 1
        cached = nil
        loaded = true
        lock.unlock()
    }
}

/// Reads only the tail of a growing JSONL file. A partial first line is dropped, which is
/// safe because callers only ever want whole trailing records.
enum TailReader {
    static func tailLines(of url: URL, maxBytes: Int = 65_536) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(whereSeparator: \.isNewline)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

public struct CorrectionEntry: Codable, Equatable {
    public var ts: String
    public var app: String
    public var style: String
    public var typed: String
    public var corrected: String

    public init(ts: String, app: String, style: String, typed: String, corrected: String) {
        self.ts = ts
        self.app = app
        self.style = style
        self.typed = typed
        self.corrected = corrected
    }
}

public enum CorrectionStore {
    public static func append(_ e: CorrectionEntry, to url: URL = VoicePopPaths.corrections) {
        do {
            try appendThrowing(e, to: url)
        } catch {
            fputs("VoicePop: corrections append failed: \(error)\n", stderr)
        }
    }

    /// Throwing sibling of `append`, for callers (the correction window) that must show the user
    /// an actionable error instead of silently swallowing it.
    public static func appendThrowing(_ e: CorrectionEntry, to url: URL = VoicePopPaths.corrections) throws {
        try VoicePopPaths.ensureDir()
        try VoicePopPaths.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(e) + Data("\n".utf8)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw AppendError.openFailed(errno) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw AppendError.writeFailed(errno) }
        try appendAll(fd: fd, data: data)
    }

    public static func recent(limit: Int, from url: URL = VoicePopPaths.corrections) -> [CorrectionEntry] {
        try? VoicePopPaths.ensureDir()
        let lines = TailReader.tailLines(of: url).filter { !$0.isEmpty }
        return lines.suffix(limit).compactMap { line in
            try? JSONDecoder().decode(CorrectionEntry.self, from: Data(line.utf8))
        }
    }
}

public struct Replacement: Codable, Equatable {
    public var from: String
    public var to: String
    public var count: Int
    public var lastTs: String
    /// Per-entry keys this version does not recognize, preserved on save.
    public var unknownFields: [String: JSONValue] = [:]

    public init(from: String, to: String, count: Int, lastTs: String) {
        self.from = from
        self.to = to
        self.count = count
        self.lastTs = lastTs
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case from, to, count, lastTs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.from = try c.decode(String.self, forKey: .from)
        self.to = try c.decode(String.self, forKey: .to)
        self.count = try c.decode(Int.self, forKey: .count)
        self.lastTs = try c.decode(String.self, forKey: .lastTs)
        unknownFields = UnknownFieldCapture.extra(from: decoder, knownKeys: CodingKeys.allCases.map(\.stringValue))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(count, forKey: .count)
        try c.encode(lastTs, forKey: .lastTs)
        try UnknownFieldCapture.encode(unknownFields, to: encoder)
    }
}

/// Validation error for a Learned Words edit, surfaced verbatim in the Settings UI.
public enum ReplacementValidationError: Error, LocalizedError, Equatable {
    case fromTooShort
    case toEmpty
    case fromEqualsTo
    case duplicateFrom

    public var errorDescription: String? {
        switch self {
        case .fromTooShort: return "The original word or phrase must be at least 2 characters."
        case .toEmpty: return "The replacement text can't be empty."
        case .fromEqualsTo: return "The replacement must be different from the original."
        case .duplicateFrom: return "That word or phrase is already learned. Edit the existing entry instead."
        }
    }
}

public struct Replacements: Codable, Equatable {
    static let iso8601 = ISO8601DateFormatter()

    public var version = 1
    public var entries: [Replacement] = []
    /// Top-level keys this version does not recognize, preserved on save.
    public var unknownFields: [String: JSONValue] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([Replacement].self, forKey: .entries) ?? []
        unknownFields = UnknownFieldCapture.extra(from: decoder, knownKeys: CodingKeys.allCases.map(\.stringValue))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(entries, forKey: .entries)
        try UnknownFieldCapture.encode(unknownFields, to: encoder)
    }

    /// Validates a Learned Words edit against the same rules `apply` uses at runtime, so an entry
    /// that would be silently ineffective is instead rejected in the UI. `excluding` is the
    /// existing entry's `from` key when editing in place (so it isn't flagged as its own duplicate).
    public static func validate(from: String, to: String, existing: [Replacement], excluding: String? = nil) -> ReplacementValidationError? {
        let trimmedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedFrom.count >= 2 else { return .fromTooShort }
        guard !trimmedTo.isEmpty else { return .toEmpty }
        guard trimmedFrom.caseInsensitiveCompare(trimmedTo) != .orderedSame else { return .fromEqualsTo }
        let key = DiffLearner.key(trimmedFrom)
        for e in existing {
            if let excluding, DiffLearner.key(excluding) == key { continue }
            if DiffLearner.key(e.from) == key { return .duplicateFrom }
        }
        return nil
    }

    public enum LoadResult: Equatable {
        case missing
        case ready(Replacements)
        case corrupt
    }

    public static func inspect(from url: URL = VoicePopPaths.replacements) -> LoadResult {
        try? VoicePopPaths.ensureDir()
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Replacements.self, from: data)
        else { return .corrupt }
        return .ready(decoded)
    }

    /// Missing or corrupt files yield an empty set for this run. Do not save over a corrupt file.
    public static func load(from url: URL = VoicePopPaths.replacements) -> Replacements {
        if case .ready(let decoded) = inspect(from: url) { return decoded }
        return Replacements()
    }

    public func save(to url: URL = VoicePopPaths.replacements) throws {
        try VoicePopPaths.ensureDir()
        try VoicePopPaths.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try VoicePopPaths.secureFile(url)
    }

    public mutating func learn(typed: String, corrected: String, maxPhraseWords: Int, now: Date = Date()) {
        let pairs = DiffLearner.substitutions(
            typed: DiffLearner.tokenize(typed),
            corrected: DiffLearner.tokenize(corrected),
            maxPhraseWords: maxPhraseWords
        )
        let ts = Replacements.iso8601.string(from: now)
        for pair in pairs {
            if let idx = entries.firstIndex(where: { $0.from == pair.from }) {
                if entries[idx].to == pair.to {
                    entries[idx].count += 1
                    entries[idx].lastTs = ts
                } else {
                    entries[idx].to = pair.to
                    entries[idx].count = 1
                    entries[idx].lastTs = ts
                }
            } else {
                entries.append(Replacement(from: pair.from, to: pair.to, count: 1, lastTs: ts))
            }
        }
        if entries.count > 500 {
            entries.sort { ($0.count, $0.lastTs) > ($1.count, $1.lastTs) }
            entries.removeLast(entries.count - 500)
        }
    }

    public func apply(to text: String, minCount: Int) -> String {
        let active = entries.filter { $0.count >= minCount && !$0.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !active.isEmpty else { return text }
        let sorted = active.sorted {
            let aw = $0.from.split(separator: " ").count
            let bw = $1.from.split(separator: " ").count
            if aw != bw { return aw > bw }
            return $0.from.count > $1.from.count
        }
        var lookup: [String: String] = [:]
        for e in sorted {
            let from = e.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard from.count >= 2 else { continue }
            let key = from.lowercased()
            if lookup[key] == nil { lookup[key] = e.to }
        }
        guard !lookup.isEmpty else { return text }
        let alternation = sorted
            .map { $0.from.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternation + ")(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let matched = ns.substring(with: m.range).lowercased()
            out += lookup[matched] ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    public func glossary(limit: Int) -> [String] {
        var best: [String: Replacement] = [:]
        for e in entries {
            if let existing = best[e.to] {
                if e.count > existing.count || (e.count == existing.count && e.lastTs > existing.lastTs) {
                    best[e.to] = e
                }
            } else {
                best[e.to] = e
            }
        }
        return best.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.lastTs > $1.lastTs
        }.prefix(limit).map(\.to)
    }
}

public enum DiffLearner {
    public static let punctChars = CharacterSet(charactersIn: ",.;:!?;\"'“”‘’()[]{}")

    public static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func key(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: punctChars)
    }

    public static func substitutions(
        typed: [String],
        corrected: [String],
        maxPhraseWords: Int
    ) -> [(from: String, to: String)] {
        if typed.count > 400 || corrected.count > 400 { return [] }
        let n = typed.count
        let m = corrected.count
        if n == 0 && m == 0 { return [] }
        let tk = typed.map(key)
        let ck = corrected.map(key)

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    if tk[i - 1] == ck[j - 1] {
                        dp[i][j] = dp[i - 1][j - 1] + 1
                    } else {
                        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                    }
                }
            }
        }

        var matches: [(Int, Int)] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            if tk[i - 1] == ck[j - 1] {
                matches.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        matches.reverse()

        var result: [(from: String, to: String)] = []
        var ti = 0
        var ci = 0
        func emit(from fromToks: ArraySlice<String>, to toToks: ArraySlice<String>) {
            guard !fromToks.isEmpty, !toToks.isEmpty,
                  (1...maxPhraseWords).contains(fromToks.count),
                  (1...maxPhraseWords).contains(toToks.count)
            else { return }
            let from = fromToks.map(key).joined(separator: " ")
            let to = toToks.map { $0.trimmingCharacters(in: punctChars) }.joined(separator: " ")
            guard from.count >= 2, from != to.lowercased() else { return }
            result.append((from, to))
        }
        for (mi, mj) in matches {
            emit(from: typed[ti..<mi], to: corrected[ci..<mj])
            let t = typed[mi]
            let c = corrected[mj]
            let cTrim = c.trimmingCharacters(in: punctChars)
            let sentenceStart = mj == 0 || corrected[mj - 1].last.map { ".!?".contains($0) } == true
            // Same word, different casing, not at a sentence start → proper-noun spelling.
            if !sentenceStart, cTrim.count >= 2, key(t) == key(cTrim), cTrim != key(t),
               cTrim.contains(where: \.isUppercase), t.trimmingCharacters(in: punctChars) != cTrim {
                result.append((key(t), cTrim))
            }
            ti = mi + 1
            ci = mj + 1
        }
        emit(from: typed[ti...], to: corrected[ci...])
        return result
    }
}

/// Testable save logic for the correction window (§4): appends a `corrections.jsonl` record and
/// learns replacements from an edited transcript. Injectable URLs so tests never touch real
/// config. One instance per open correction window: it remembers which (entry, edited-text) pair
/// it already appended, so retrying after a failure never writes a duplicate `corrections.jsonl`
/// record even though `learn`/`save` may be retried.
public final class CorrectionSaver {
    public enum SaveError: Error, LocalizedError, Equatable {
        case correctionAppendFailed(String)
        case replacementsCorrupt
        case replacementsQuarantineFailed(String)
        case replacementsSaveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .correctionAppendFailed(let detail):
                return "Couldn't save the correction. \(detail)"
            case .replacementsCorrupt:
                return "replacements.json can't be read. It was moved aside so it isn't overwritten; a fresh file will be created."
            case .replacementsQuarantineFailed(let detail):
                return "replacements.json can't be read, and moving it aside also failed (\(detail)). It was not changed."
            case .replacementsSaveFailed(let detail):
                return "Couldn't save learned words. \(detail)"
            }
        }
    }

    private let correctionsURL: URL
    private let replacementsURL: URL
    private var appendedKey: String?

    public init(
        correctionsURL: URL = VoicePopPaths.corrections,
        replacementsURL: URL = VoicePopPaths.replacements
    ) {
        self.correctionsURL = correctionsURL
        self.replacementsURL = replacementsURL
    }

    /// No-op when the edited text equals the original (nothing to learn or record).
    @discardableResult
    public func save(entry: HistoryEntry, correctedText: String, maxPhraseWords: Int, now: Date = Date()) throws -> Bool {
        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != entry.out, !trimmed.isEmpty else { return false }

        let key = entry.ts + "\u{0}" + trimmed
        if appendedKey != key {
            do {
                try CorrectionStore.appendThrowing(
                    CorrectionEntry(
                        ts: ISO8601DateFormatter().string(from: now),
                        app: entry.app,
                        style: entry.style,
                        typed: entry.out,
                        corrected: trimmed
                    ),
                    to: correctionsURL
                )
                appendedKey = key
            } catch {
                throw SaveError.correctionAppendFailed(String(describing: error))
            }
        }

        switch Replacements.inspect(from: replacementsURL) {
        case .corrupt:
            do {
                try VoicePopPaths.quarantine(replacementsURL)
            } catch {
                throw SaveError.replacementsQuarantineFailed(error.localizedDescription)
            }
            throw SaveError.replacementsCorrupt
        case .missing:
            var r = Replacements()
            r.learn(typed: entry.rules, corrected: trimmed, maxPhraseWords: maxPhraseWords, now: now)
            do { try r.save(to: replacementsURL) } catch { throw SaveError.replacementsSaveFailed(error.localizedDescription) }
        case .ready(var r):
            r.learn(typed: entry.rules, corrected: trimmed, maxPhraseWords: maxPhraseWords, now: now)
            do { try r.save(to: replacementsURL) } catch { throw SaveError.replacementsSaveFailed(error.localizedDescription) }
        }
        return true
    }
}
