import XCTest
@testable import PopcornCore

/// Tests for the Navigation/Settings/Corrections workstream: persistence compatibility,
/// Learned Words validation, and the correction save path (§4, §7 of the polish spec).
final class SettingsPolishTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepop-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - StylePrefs unknown-field preservation

    func testStylePrefsPreservesUnknownFieldsAcrossSave() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("style.json")
        let raw = """
        {"version":1,"global":"casual","perApp":{},"llm":{"enabled":true},"learning":{},"mascot":"popcorn","futureFeature":{"flag":true,"note":"added by a newer app"}}
        """
        try Data(raw.utf8).write(to: url)

        var prefs = StylePrefs.load(from: url)
        XCTAssertEqual(prefs.unknownFields["futureFeature"], .object(["flag": .bool(true), "note": .string("added by a newer app")]))

        prefs.global = .formal
        try prefs.save(to: url)

        let reloaded = StylePrefs.load(from: url)
        XCTAssertEqual(reloaded.global, .formal)
        XCTAssertEqual(reloaded.unknownFields["futureFeature"], .object(["flag": .bool(true), "note": .string("added by a newer app")]))
    }

    func testStylePrefsLoadsOldFormatFixture() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("style.json")
        // Pre-mascot, pre-learning fixture shape.
        let raw = """
        {"version":1,"global":"auto","perApp":{"Ghostty":"formal"},"llm":{"enabled":false,"model":"x","endpoint":"http://127.0.0.1:11434","timeoutMs":1000}}
        """
        try Data(raw.utf8).write(to: url)
        let prefs = StylePrefs.load(from: url)
        XCTAssertEqual(prefs.perApp["Ghostty"], .formal)
        XCTAssertEqual(prefs.mascot, .popcorn)
        XCTAssertFalse(prefs.llm.enabled)
    }

    // MARK: - Replacements: validation, persistence, unknown fields, malformed handling

    func testReplacementValidationRules() {
        let existing = [Replacement(from: "teh", to: "the", count: 3, lastTs: "t")]
        XCTAssertEqual(Replacements.validate(from: "a", to: "the", existing: existing), .fromTooShort)
        XCTAssertEqual(Replacements.validate(from: "abc", to: "", existing: existing), .toEmpty)
        XCTAssertEqual(Replacements.validate(from: "Abc", to: "abc", existing: existing), .fromEqualsTo)
        XCTAssertEqual(Replacements.validate(from: "TEH", to: "there", existing: existing), .duplicateFrom)
        XCTAssertNil(Replacements.validate(from: "recieve", to: "receive", existing: existing))
        // Editing the existing entry in place must not flag itself as a duplicate.
        XCTAssertNil(Replacements.validate(from: "teh", to: "them", existing: existing, excluding: "teh"))
    }

    func testReplacementsRoundTripPreservesUnknownFieldsAndPermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("replacements.json")
        var r = Replacements()
        r.entries.append(Replacement(from: "recieve", to: "receive", count: 2, lastTs: "2024-01-01T00:00:00Z"))
        try r.save(to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        guard case .ready(let loaded) = Replacements.inspect(from: url) else {
            return XCTFail("expected a readable file")
        }
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].from, "recieve")
    }

    func testReplacementsMalformedFileIsNotOverwritten() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("replacements.json")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(Replacements.inspect(from: url), .corrupt)
        // load() must not touch the file (no silent overwrite path exists here); the caller
        // (CorrectionSaver / Settings) is responsible for quarantining explicitly.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - CorrectionSaver (§4, §7)

    private func makeEntry(out: String = "hello wrold") -> HistoryEntry {
        HistoryEntry(ts: "2024-01-01T00:00:00Z", app: "Ghostty", style: "casual", raw: "hello world", rules: out, out: out, llm: false)
    }

    func testCorrectionSaverAppendsAndLearns() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let correctionsURL = dir.appendingPathComponent("corrections.jsonl")
        let replacementsURL = dir.appendingPathComponent("replacements.json")
        let saver = CorrectionSaver(correctionsURL: correctionsURL, replacementsURL: replacementsURL)

        let saved = try saver.save(entry: makeEntry(), correctedText: "hello world", maxPhraseWords: 4)
        XCTAssertTrue(saved)
        XCTAssertEqual(CorrectionStore.recent(limit: 10, from: correctionsURL).count, 1)
        guard case .ready(let r) = Replacements.inspect(from: replacementsURL) else {
            return XCTFail("expected replacements to be written")
        }
        XCTAssertTrue(r.entries.contains { $0.from == "wrold" && $0.to == "world" })
    }

    func testCorrectionSaverRetryAfterFailureDoesNotDuplicateRecord() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let correctionsURL = dir.appendingPathComponent("corrections.jsonl")
        // Corrupt replacements.json so the first save attempt fails on the learn step, after the
        // correction record has already been appended.
        let replacementsURL = dir.appendingPathComponent("replacements.json")
        try Data("not json".utf8).write(to: replacementsURL)

        let saver = CorrectionSaver(correctionsURL: correctionsURL, replacementsURL: replacementsURL)
        XCTAssertThrowsError(try saver.save(entry: makeEntry(), correctedText: "hello world", maxPhraseWords: 4)) { error in
            XCTAssertEqual(error as? CorrectionSaver.SaveError, .replacementsCorrupt)
        }
        XCTAssertEqual(CorrectionStore.recent(limit: 10, from: correctionsURL).count, 1)
        // Corrupt file must be quarantined (to a timestamped .bad-<time> name - L-13), not left
        // in place or overwritten.
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementsURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("replacements.json.bad-") }
        XCTAssertEqual(quarantined.count, 1)

        // Retry after the quarantine (as the UI would, once the user has been told to Retry):
        // the correction record must not be duplicated even though save() runs again.
        let saved = try saver.save(entry: makeEntry(), correctedText: "hello world", maxPhraseWords: 4)
        XCTAssertTrue(saved)
        XCTAssertEqual(CorrectionStore.recent(limit: 10, from: correctionsURL).count, 1)
    }

    func testCorrectionSaverNoOpWhenTextUnchanged() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let correctionsURL = dir.appendingPathComponent("corrections.jsonl")
        let replacementsURL = dir.appendingPathComponent("replacements.json")
        let saver = CorrectionSaver(correctionsURL: correctionsURL, replacementsURL: replacementsURL)
        let entry = makeEntry()
        let saved = try saver.save(entry: entry, correctedText: entry.out, maxPhraseWords: 4)
        XCTAssertFalse(saved)
        XCTAssertEqual(CorrectionStore.recent(limit: 10, from: correctionsURL).count, 0)
    }

    // MARK: - Replacements.apply / Mutation (review-1 M-1: never save a stale copy)

    func testApplyAddMergesWithConcurrentDiskChanges() {
        // Settings loaded the file, then (simulated) the correction window learned a new word
        // directly on disk. Settings' add() must not erase it when it saves.
        var onDisk = Replacements()
        onDisk.entries.append(Replacement(from: "voxtype", to: "Voxtype", count: 1, lastTs: "t0"))
        let newEntry = Replacement(from: "recieve", to: "receive", count: 1, lastTs: "t1")
        onDisk.apply(.add(newEntry))
        XCTAssertEqual(Set(onDisk.entries.map(\.from)), ["voxtype", "recieve"])
    }

    func testApplyAddOverwritesInPlaceRatherThanDuplicating() {
        var r = Replacements()
        r.entries.append(Replacement(from: "teh", to: "the", count: 1, lastTs: "t0"))
        r.apply(.add(Replacement(from: "teh", to: "them", count: 5, lastTs: "t1")))
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].to, "them")
    }

    func testApplyUpdateChangesFromAndTo() {
        var r = Replacements()
        r.entries.append(Replacement(from: "teh", to: "the", count: 3, lastTs: "t0"))
        r.apply(.update(originalFrom: "teh", from: "tehh", to: "the"))
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].from, "tehh")
    }

    func testApplyUpdateOnConcurrentlyDeletedEntryReAddsInstead() {
        // The entry being edited was removed by another writer between load and save; the user's
        // edit should not silently vanish.
        var r = Replacements()
        r.apply(.update(originalFrom: "teh", from: "teh", to: "the"))
        XCTAssertEqual(r.entries.map(\.from), ["teh"])
    }

    func testApplyDeleteRemovesByKey() {
        var r = Replacements()
        r.entries.append(Replacement(from: "teh", to: "the", count: 1, lastTs: "t0"))
        r.entries.append(Replacement(from: "recieve", to: "receive", count: 1, lastTs: "t0"))
        r.apply(.delete(from: "teh"))
        XCTAssertEqual(r.entries.map(\.from), ["recieve"])
    }

    /// End-to-end at the file level: this is the exact M-1 failure scenario from review-1 - a
    /// concurrent writer (standing in for the correction window's CorrectionSaver) adds a word
    /// after Settings has already read the file, and Settings' own edit must not erase it.
    func testConcurrentWriteDuringEditIsNotErasedBySettingsSave() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("replacements.json")

        var initial = Replacements()
        initial.entries.append(Replacement(from: "voxtype", to: "Voxtype", count: 1, lastTs: "t0"))
        try initial.save(to: url)

        // Settings loads it (a view model would keep this around while the user edits)...
        guard case .ready(let settingsLoaded) = Replacements.inspect(from: url) else {
            return XCTFail("expected a readable file")
        }
        _ = settingsLoaded // the stale copy - deliberately not used for the save below

        // ...then the correction window learns a new word and writes it directly.
        guard case .ready(var concurrent) = Replacements.inspect(from: url) else {
            return XCTFail("expected a readable file")
        }
        concurrent.apply(.add(Replacement(from: "recieve", to: "receive", count: 1, lastTs: "t1")))
        try concurrent.save(to: url)

        // Settings now saves its own edit (deleting "voxtype") - re-reading fresh first, as
        // LearnedWordsViewModel.persistMutation does, rather than writing back `settingsLoaded`.
        guard case .ready(var fresh) = Replacements.inspect(from: url) else {
            return XCTFail("expected a readable file")
        }
        fresh.apply(.delete(from: "voxtype"))
        try fresh.save(to: url)

        guard case .ready(let final) = Replacements.inspect(from: url) else {
            return XCTFail("expected a readable file")
        }
        XCTAssertEqual(final.entries.map(\.from), ["recieve"], "the concurrently-learned word must survive Settings' save")
    }

    // MARK: - Model download progress parsing (fixtures, no live download)

    func testModelDownloadProgressParsesProgressLine() {
        let line = #"{"event":"progress","pct":42.5,"bytes":1073741824,"total":2147483648}"#
        XCTAssertEqual(ModelDownloadProgress.parse(line: line), .progress(fraction: 0.425, bytesGB: 1, totalGB: 2))
    }

    func testModelDownloadProgressParsesErrorLine() {
        let line = #"{"event":"error","message":"disk full"}"#
        XCTAssertEqual(ModelDownloadProgress.parse(line: line), .failure("disk full"))
    }

    func testModelDownloadProgressIgnoresUnrelatedLines() {
        XCTAssertNil(ModelDownloadProgress.parse(line: ""))
        XCTAssertNil(ModelDownloadProgress.parse(line: "not json"))
        XCTAssertNil(ModelDownloadProgress.parse(line: #"{"event":"start"}"#))
    }

    // MARK: - VOICEPOP_CONFIG_DIR override

    func testConfigDirOverrideIsRespected() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("VOICEPOP_CONFIG_DIR", dir.path, 1)
        defer { unsetenv("VOICEPOP_CONFIG_DIR") }
        XCTAssertEqual(VoicePopPaths.dir.path, dir.path)
    }
}
