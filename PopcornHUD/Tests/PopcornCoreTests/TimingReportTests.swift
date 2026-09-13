import Foundation
import XCTest
@testable import PopcornCore

final class TimingReportTests: XCTestCase {
    private let t0 = TimingReport.parseWall("2026-09-12T20:00:00.000Z")!

    private func line(_ ms: Double, _ proc: String, _ name: String, _ fields: KeyValuePairs<String, String> = [:]) -> String {
        Timing.line(name: name, fields: fields, monoUs: UInt64(ms * 1000), wall: t0.addingTimeInterval(ms / 1000))
            .replacingOccurrences(of: "proc=\(Timing.processTag)", with: "proc=\(proc)")
    }

    func testLineRoundTripsAndSanitizesValues() {
        let raw = Timing.line(name: "clean.done", fields: ["llm": "time out", "ms": "12"], monoUs: 1_234_567, wall: t0)
        XCTAssertTrue(raw.hasSuffix("\n"))
        let e = TimingReport.parse(line: String(raw.dropLast()))
        XCTAssertEqual(e?.monoMs ?? 0, 1234.567, accuracy: 0.0001)
        XCTAssertEqual(e?.name, "clean.done")
        XCTAssertEqual(e?.fields, ["llm": "time_out", "ms": "12"])
        XCTAssertEqual(e?.wall, t0)
    }

    func testVoxtypeLogKeepsOnlyTimestampsAndKinds() {
        let started = "\u{1B}[2m2026-09-12T23:47:45.766270Z\u{1B}[0m \u{1B}[32m INFO\u{1B}[0m Recording started"
        let typed = "\u{1B}[2m2026-09-12T23:47:47.025406Z\u{1B}[0m \u{1B}[32m INFO\u{1B}[0m Text typed via CGEvent (14 chars)"
        let transcript = "\u{1B}[2m2026-09-12T23:47:47.004204Z\u{1B}[0m \u{1B}[32m INFO\u{1B}[0m Transcribed: \"Recording started\""
        let a = TimingReport.parseVoxtypeLog(line: started)
        XCTAssertEqual(a?.kind, .recordingStarted)
        XCTAssertEqual(a!.wall.timeIntervalSince1970, TimingReport.parseWall("2026-09-12T23:47:45Z")!.timeIntervalSince1970 + 0.76627, accuracy: 0.000_01)
        XCTAssertEqual(TimingReport.parseVoxtypeLog(line: typed)?.kind, .typed)
        // A transcript that happens to contain a marker must not count (and its text is never kept).
        XCTAssertNil(TimingReport.parseVoxtypeLog(line: transcript))
    }

    func testDictationSessionIntervals() {
        let log = [
            line(1000, "hud", "record.request", ["cmd": "toggle"]),
            line(1040, "hud", "state.observed", ["from": "idle", "to": "recording"]),
            line(1041, "hud", "state.delivered", ["state": "recording"]),
            line(1050, "hud", "hud.visible"),
            line(1058, "hud", "hud.frame"),
            line(1100, "hud", "audio.react", ["ms": "12.5"]),
            line(1120, "hud", "audio.react", ["ms": "20"]),
            line(1130, "hud", "hud.publish", ["us": "150"]),
            line(5040, "hud", "state.observed", ["from": "recording", "to": "transcribing"]),
            line(5240, "clean", "clean.start"),
            line(5260, "clean", "clean.done", ["llm": "off", "ms": "20"]),
            line(5262, "hud", "transcript.ready"),
            line(5300, "hud", "state.observed", ["from": "transcribing", "to": "idle"]),
        ].joined()
        let events = log.split(separator: "\n").compactMap { TimingReport.parse(line: String($0)) }
        XCTAssertEqual(events.count, 13)
        let rows = Dictionary(uniqueKeysWithValues: TimingReport.analyze(events: events).map { ($0.name, $0) })
        func value(_ name: String) -> [Double] { rows[name]?.values ?? [] }
        XCTAssertEqual(value("menu request → recording state observed"), [40])
        XCTAssertEqual(value("recording state observed → main-queue delivery"), [1])
        XCTAssertEqual(value("recording state observed → first visible publish"), [10])
        XCTAssertEqual(value("recording state observed → first frame tick after publish"), [18])
        XCTAssertEqual(value("fresh audio packet → HUD publish"), [12.5, 20])
        XCTAssertEqual(value("recording duration"), [4000])
        XCTAssertEqual(value("state left recording → voxtype-clean start (recognition done)"), [200])
        XCTAssertEqual(value("voxtype-clean start → text ready [llm=off]"), [20])
        XCTAssertEqual(value("state left recording → text ready [llm=off]"), [220])
        XCTAssertEqual(value("3–10 s utterance: state left recording → text ready [llm=off]"), [220])
        XCTAssertEqual(value("text ready → HUD notified"), [2])
        XCTAssertEqual(rows["fresh audio packet → HUD publish"]?.p95, 20)
    }

    func testCancelledRecordingDoesNotPairWithLaterCleanup() {
        let log = [
            line(0, "hud", "state.observed", ["from": "idle", "to": "recording"]),
            line(500, "hud", "state.observed", ["from": "recording", "to": "idle"]),
            line(900, "hud", "state.observed", ["from": "idle", "to": "recording"]),
            line(2900, "hud", "state.observed", ["from": "recording", "to": "transcribing"]),
            line(3000, "clean", "clean.start"),
            line(3010, "clean", "clean.done", ["llm": "used"]),
        ].joined()
        let events = log.split(separator: "\n").compactMap { TimingReport.parse(line: String($0)) }
        let rows = Dictionary(uniqueKeysWithValues: TimingReport.analyze(events: events).map { ($0.name, $0.values) })
        XCTAssertEqual(rows["recording duration"], [500, 2000])
        XCTAssertEqual(rows["state left recording → text ready [llm=used]"], [110])
        XCTAssertNil(rows["3–10 s utterance: state left recording → text ready [llm=used]"])
    }

    func testPercentileNearestRank() {
        XCTAssertEqual(TimingReport.percentile(Array(1...20).map(Double.init), 0.95), 19)
        XCTAssertEqual(TimingReport.percentile([5], 0.5), 5)
        XCTAssertTrue(TimingReport.percentile([], 0.5).isNaN)
    }

    func testSinkIsOwnerOnlyAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("logs/timing.log")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: Int(Timing.rotateBytes) + 1),
                                       attributes: [.posixPermissions: 0o644])
        let fd = Timing.openSink(url)
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.intValue, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".1"))

        let fresh = dir.appendingPathComponent("new/timing.log")
        let fd2 = Timing.openSink(fresh)
        XCTAssertGreaterThanOrEqual(fd2, 0)
        close(fd2)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: fresh.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
