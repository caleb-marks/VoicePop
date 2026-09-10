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
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(e) + Data("\n".utf8)
            var fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { throw AppendError.openFailed(errno) }
            var st = stat()
            if fstat(fd, &st) == 0, st.st_size > 1_048_576 {
                close(fd)
                if FileManager.default.fileExists(atPath: rotated.path) {
                    try FileManager.default.removeItem(at: rotated)
                }
                try FileManager.default.moveItem(at: url, to: rotated)
                fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
                guard fd >= 0 else { throw AppendError.openFailed(errno) }
            }
            defer { close(fd) }
            try appendAll(fd: fd, data: data)
        } catch {
            fputs("VoicePop: history append failed: \(error)\n", stderr)
        }
    }

    public static func last(from url: URL = VoicePopPaths.history) -> HistoryEntry? {
        guard let line = TailReader.tailLines(of: url).last(where: { !$0.isEmpty }) else {
            return nil
        }
        return try? JSONDecoder().decode(HistoryEntry.self, from: Data(line.utf8))
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
            try VoicePopPaths.ensureDir()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(e) + Data("\n".utf8)
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { throw AppendError.openFailed(errno) }
            defer { close(fd) }
            try appendAll(fd: fd, data: data)
        } catch {
            fputs("VoicePop: corrections append failed: \(error)\n", stderr)
        }
    }

    public static func recent(limit: Int, from url: URL = VoicePopPaths.corrections) -> [CorrectionEntry] {
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

    public init(from: String, to: String, count: Int, lastTs: String) {
        self.from = from
        self.to = to
        self.count = count
        self.lastTs = lastTs
    }
}

public struct Replacements: Codable, Equatable {
    static let iso8601 = ISO8601DateFormatter()

    public var version = 1
    public var entries: [Replacement] = []

    public init() {}

    public enum LoadResult: Equatable {
        case missing
        case ready(Replacements)
        case corrupt
    }

    public static func inspect(from url: URL = VoicePopPaths.replacements) -> LoadResult {
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
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
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
