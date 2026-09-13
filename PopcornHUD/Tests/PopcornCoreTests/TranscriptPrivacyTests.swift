import XCTest
@testable import PopcornCore

/// "Save transcript history" (Settings → General → Privacy): persistence defaults, the single
/// write gate `voxtype-clean` goes through, and the separation between history, corrections,
/// and learned words.
final class TranscriptPrivacyTests: XCTestCase {
    /// Not pre-created: `VoicePopPaths.ensurePrivateDirectory` only chmods a directory it
    /// creates itself, and the owner-only assertions below cover that path.
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepop-privacy-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(_ ts: String) -> HistoryEntry {
        HistoryEntry(ts: ts, app: "Notes", style: "auto", raw: "hello wrold", rules: "Hello wrold", out: "Hello wrold", llm: false)
    }

    // MARK: - Persistence

    func testSaveHistoryDefaultsOnForOlderStyleFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("style.json")
        // A style.json written before the privacy key existed.
        try Data(#"{"version":1,"global":"casual","perApp":{},"llm":{"enabled":true},"learning":{},"mascot":"popcorn"}"#.utf8).write(to: url)
        XCTAssertTrue(StylePrefs.load(from: url).privacy.saveHistory)
        XCTAssertTrue(StylePrefs.default.privacy.saveHistory)
        // An empty privacy object also means "on".
        try Data(#"{"privacy":{}}"#.utf8).write(to: url)
        XCTAssertTrue(StylePrefs.load(from: url).privacy.saveHistory)
    }

    func testSaveHistoryOffRoundTripsAndKeepsOtherPrefs() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("style.json")
        var prefs = StylePrefs()
        prefs.global = .formal
        prefs.privacy.saveHistory = false
        try prefs.save(to: url)

        let reloaded = StylePrefs.load(from: url)
        XCTAssertFalse(reloaded.privacy.saveHistory)
        XCTAssertEqual(reloaded.global, .formal)
        XCTAssertEqual(reloaded, prefs)
        let json = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(json.contains(#""saveHistory" : false"#), json)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - The write gate

    func testRecordWritesNothingWhenHistoryIsOff() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = dir.appendingPathComponent("history.jsonl")
        let rotated = dir.appendingPathComponent("history.1.jsonl")
        var prefs = StylePrefs()
        prefs.privacy.saveHistory = false

        XCTAssertFalse(HistoryStore.record(entry("1"), prefs: prefs, to: history, rotated: rotated))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path), "no history file may be created while the setting is off")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated.path))
        XCTAssertNil(HistoryStore.last(from: history))
    }

    func testRecordAppendsOwnerOnlyWhenHistoryIsOn() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = dir.appendingPathComponent("history.jsonl")
        let rotated = dir.appendingPathComponent("history.1.jsonl")

        XCTAssertTrue(HistoryStore.record(entry("1"), prefs: StylePrefs(), to: history, rotated: rotated))
        XCTAssertEqual(HistoryStore.last(from: history)?.ts, "1")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: history.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTurningHistoryOffKeepsExistingEntriesUntilCleared() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = dir.appendingPathComponent("history.jsonl")
        let rotated = dir.appendingPathComponent("history.1.jsonl")
        var prefs = StylePrefs()
        XCTAssertTrue(HistoryStore.record(entry("before"), prefs: prefs, to: history, rotated: rotated))

        prefs.privacy.saveHistory = false
        XCTAssertFalse(HistoryStore.record(entry("after"), prefs: prefs, to: history, rotated: rotated))
        // Fix Last Dictation still sees the last entry saved *before* the switch was turned off.
        XCTAssertEqual(HistoryStore.last(from: history)?.ts, "before")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: history.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Deletion is a separate, explicit step.
        try HistoryStore.clear(active: history, rotated: rotated)
        XCTAssertNil(HistoryStore.last(from: history))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
    }

    func testHistorySettingDoesNotGovernCorrectionsOrLearnedWords() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = dir.appendingPathComponent("history.jsonl")
        let corrections = dir.appendingPathComponent("corrections.jsonl")
        let replacements = dir.appendingPathComponent("replacements.json")
        var prefs = StylePrefs()
        prefs.privacy.saveHistory = false

        XCTAssertFalse(HistoryStore.record(entry("1"), prefs: prefs, to: history, rotated: dir.appendingPathComponent("history.1.jsonl")))
        // Save & Learn from an entry that is still open in the correction window keeps working.
        let saver = CorrectionSaver(correctionsURL: corrections, replacementsURL: replacements)
        XCTAssertTrue(try saver.save(entry: entry("1"), correctedText: "Hello world", maxPhraseWords: 4))
        XCTAssertEqual(CorrectionStore.recent(limit: 1, from: corrections).first?.corrected, "Hello world")
        XCTAssertEqual(Replacements.load(from: replacements).entries.map(\.to), ["world"], "learned words are still written with history off")
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        for url in [corrections, replacements] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
}
