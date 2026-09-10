import XCTest
@testable import PopcornCore

final class AudioFrameTests: XCTestCase {
    func testDecodeRoundTrip() {
        let f = AudioFrame(seq: 42, min: -0.2, max: 0.5, peakDbfs: -6)
        let bytes = f.encode()
        let decoded = AudioFrame.decode(bytes[...])!
        XCTAssertEqual(decoded.seq, 42)
        XCTAssertEqual(decoded.min, -0.2, accuracy: 0.0001)
        XCTAssertEqual(decoded.max, 0.5, accuracy: 0.0001)
        XCTAssertEqual(decoded.peak, 0.5, accuracy: 0.0001)
    }

    func testFragmentedBuffer() {
        let f1 = AudioFrame(seq: 1, min: 0.1, max: 0.2, peakDbfs: -12)
        let f2 = AudioFrame(seq: 2, min: -0.3, max: 0.1, peakDbfs: -10)
        var all = f1.encode() + f2.encode()
        let buf = AudioFrameBuffer()
        let part1 = Array(all.prefix(10))
        let part2 = Array(all.dropFirst(10))
        XCTAssertTrue(buf.append(part1).isEmpty)
        let frames = buf.append(part2)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].seq, 1)
        XCTAssertEqual(frames[1].seq, 2)
    }

    func testCombinedMessages() {
        let frames = (0..<3).map { AudioFrame(seq: UInt32($0), min: 0, max: Float($0) * 0.1, peakDbfs: -20) }
        let bytes = frames.flatMap { $0.encode() }
        let buf = AudioFrameBuffer()
        let out = buf.append(bytes)
        XCTAssertEqual(out.count, 3)
    }

    func testRejectNonFinite() {
        var bytes = AudioFrame(seq: 1, min: 0, max: 0.1, peakDbfs: -5).encode()
        var nan = Float.nan.bitPattern.littleEndian
        withUnsafeBytes(of: &nan) { raw in
            for i in 0..<4 { bytes[8 + i] = raw[i] }
        }
        let buf = AudioFrameBuffer()
        let out = buf.append(bytes)
        XCTAssertTrue(out.isEmpty)
    }
}

final class AudioLevelHoldTests: XCTestCase {
    func testFreshHeldSilenceAndStale() {
        var hold = AudioLevelHold()
        hold.publish(peak: 0.25, monoMs: 1000)
        let fresh = hold.consume(nowMs: 1010, staleMs: 250)
        XCTAssertEqual(fresh.freshness, .fresh)
        XCTAssertEqual(fresh.peak, 0.25, accuracy: 0.0001)

        // Display tick with no new packet must hold level — not invent silence.
        let held = hold.consume(nowMs: 1020, staleMs: 250)
        XCTAssertEqual(held.freshness, .held)
        XCTAssertEqual(held.peak, 0.25, accuracy: 0.0001)

        // Silent packet promptly lowers the held level.
        hold.publish(peak: 0, monoMs: 1030)
        let silent = hold.consume(nowMs: 1040, staleMs: 250)
        XCTAssertEqual(silent.freshness, .fresh)
        XCTAssertEqual(silent.peak, 0, accuracy: 0.0001)
        let heldSilent = hold.consume(nowMs: 1050, staleMs: 250)
        XCTAssertEqual(heldSilent.freshness, .held)
        XCTAssertEqual(heldSilent.peak, 0, accuracy: 0.0001)

        // Stale window stops driving pops.
        let stale = hold.consume(nowMs: 1030 + 251, staleMs: 250)
        XCTAssertEqual(stale.freshness, .unavailable)
        XCTAssertEqual(stale.peak, 0)
    }

    func testMaxPeakAcrossPacketsAndDisconnect() {
        var hold = AudioLevelHold()
        hold.publish(peak: 0.1, monoMs: 100)
        hold.publish(peak: 0.4, monoMs: 110)
        hold.publish(peak: 0.2, monoMs: 120)
        let sample = hold.consume(nowMs: 130, staleMs: 250)
        XCTAssertEqual(sample.freshness, .fresh)
        XCTAssertEqual(sample.peak, 0.4, accuracy: 0.0001)
        // Last batch peak is what we hold afterward.
        let held = hold.consume(nowMs: 140, staleMs: 250)
        XCTAssertEqual(held.peak, 0.2, accuracy: 0.0001)

        hold.markDisconnected()
        let dead = hold.consume(nowMs: 150, staleMs: 250)
        XCTAssertEqual(dead.freshness, .unavailable)
        XCTAssertEqual(dead.peak, 0)
    }

    func testHeldSamplesDoNotManufactureOnsetAccents() {
        let sim = PopcornSim(seed: 55)
        sim.step(dt: Tunables.simDt, peak: 0.28, peakFresh: true)
        let afterFresh = sim.emittedCount
        XCTAssertGreaterThan(afterFresh, 0)
        for _ in 0..<40 {
            sim.step(dt: Tunables.simDt, peak: 0.28, peakFresh: false)
        }
        let mid = sim.emittedCount
        for _ in 0..<200 {
            sim.step(dt: Tunables.simDt, peak: 0.28, peakFresh: false)
        }
        let grown = sim.emittedCount - mid
        let expectedSteady = Int(Tunables.popsPerSecond(heat: sim.heat) * (200.0 / 120.0) + 2)
        XCTAssertLessThanOrEqual(grown, expectedSteady + 6)
    }
}

final class TextCleanTests: XCTestCase {
    func testProseCapitalize() {
        XCTAssertEqual(TextClean.clean("hello world ,", app: "TextEdit"), "Hello world,")
        XCTAssertEqual(TextClean.clean("hi ,", app: "TextEdit"), "Hi,")
    }

    func testTerminalNoCapitalize() {
        XCTAssertEqual(TextClean.clean("hello world ,", app: "Terminal"), "hello world,")
        XCTAssertEqual(TextClean.clean("hello world ,", app: "Ghostty"), "hello world,")
    }

    func testFormalPronounIBoundaries() {
        XCTAssertEqual(
            TextClean.clean("i think i.e. the i/o is fine", app: "TextEdit", style: .formal),
            "I think i.e. the i/o is fine."
        )
        XCTAssertEqual(
            TextClean.clean("i'm sure so am i", app: "TextEdit", style: .formal),
            "I'm sure so am I."
        )
        XCTAssertEqual(
            TextClean.clean("yes i did.", app: "TextEdit", style: .formal),
            "Yes I did."
        )
        XCTAssertEqual(
            TextClean.clean("so am i. then i left", app: "TextEdit", style: .formal),
            "So am I. Then I left."
        )
    }
}

final class StyleTests: XCTestCase {
    func testCasualLowercasesAndDropsTrailingPeriod() {
        XCTAssertEqual(TextClean.clean("Hello World. I think so.", app: "Messages", style: .casual), "hello world. i think so")
        XCTAssertEqual(TextClean.clean("Are you coming?", app: "Messages", style: .casual), "are you coming?")
        XCTAssertEqual(TextClean.clean("Wait...", app: "Messages", style: .casual), "wait...")
        XCTAssertEqual(TextClean.clean("don't, I won't!", app: "Messages", style: .casual), "don't, i won't!")
    }
    func testFormalSentenceCaseAndTerminalPunctuation() {
        XCTAssertEqual(TextClean.clean("hello world. i think so", app: "Mail", style: .formal), "Hello world. I think so.")
        XCTAssertEqual(TextClean.clean("i'm here, are you there? yes", app: "Mail", style: .formal), "I'm here, are you there? Yes.")
        XCTAssertEqual(TextClean.clean("see you soon,", app: "Mail", style: .formal), "See you soon.")
        XCTAssertEqual(TextClean.clean("done!", app: "Mail", style: .formal), "Done!")
        XCTAssertEqual(TextClean.clean("i.e. we ship tonight", app: "Mail", style: .formal), "i.e. we ship tonight.")
        XCTAssertEqual(TextClean.clean("see i.e. the log", app: "Mail", style: .formal), "See i.e. the log.")
    }
    func testTerminalVerbatimOnlyInAuto() {
        XCTAssertEqual(TextClean.clean("Hello World.", app: "Ghostty", style: .auto), "Hello World.")
        XCTAssertEqual(TextClean.clean("Hello World.", app: "Ghostty", style: .casual), "hello world")
        XCTAssertEqual(TextClean.clean("hello world", app: "Ghostty", style: .formal), "Hello world.")
    }
    func testAutoMatchesLegacy() {
        XCTAssertEqual(TextClean.clean("hello world ,", app: "TextEdit", style: .auto), "Hello world,")
    }
    func testResolvePerAppBeatsGlobal() {
        var p = StylePrefs.default
        p.global = .formal
        p.perApp["Messages"] = .casual
        XCTAssertEqual(p.resolve(app: "Messages"), .casual)
        XCTAssertEqual(p.resolve(app: "messages"), .casual)
        XCTAssertEqual(p.resolve(app: "Mail"), .formal)
    }
    func testPrefsDecodePartialJSON() throws {
        let p = try JSONDecoder().decode(StylePrefs.self, from: Data(#"{"global":"casual"}"#.utf8))
        XCTAssertEqual(p.global, .casual)
        XCTAssertEqual(p.llm.model, "qwen3.5:4b-mlx")
        XCTAssertEqual(p.llm.timeoutMs, 3500)
        XCTAssertEqual(p.learning.minCount, 1)
    }
    func testPrefsRoundTripToTempFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-\(UUID().uuidString)/style.json")
        var p = StylePrefs.default; p.perApp["Mail"] = .formal
        try p.save(to: url)
        XCTAssertEqual(StylePrefs.load(from: url), p)
    }
    func testCorruptStyleIsQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("style.json")
        try Data("{".utf8).write(to: url)
        XCTAssertEqual(StylePrefs.load(from: url), .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
    }
    func testMascotDefaultsToPopcornAndRoundTrips() throws {
        let empty = try JSONDecoder().decode(StylePrefs.self, from: Data(#"{}"#.utf8))
        XCTAssertEqual(empty.mascot, .popcorn)
        var beagle = StylePrefs.default
        beagle.mascot = .beagle
        let encoded = try JSONEncoder().encode(beagle)
        XCTAssertEqual(try JSONDecoder().decode(StylePrefs.self, from: encoded).mascot, .beagle)
        let named = try JSONDecoder().decode(StylePrefs.self, from: Data(#"{"mascot":"beagle"}"#.utf8))
        XCTAssertEqual(named.mascot, .beagle)
        let unknown = try JSONDecoder().decode(StylePrefs.self, from: Data(#"{"mascot":"dragon"}"#.utf8))
        XCTAssertEqual(unknown.mascot, .popcorn)
    }

    func testUnknownStyleValueDoesNotDropPrefs() throws {
        let json = Data(#"{"global":"formall","llm":{"enabled":false},"perApp":{"Mail":"formal","Notes":"casuall"}}"#.utf8)
        let p = try JSONDecoder().decode(StylePrefs.self, from: json)
        XCTAssertEqual(p.global, .auto)
        XCTAssertFalse(p.llm.enabled)
        XCTAssertEqual(p.perApp["Mail"], .formal)
        XCTAssertNil(p.perApp["Notes"])
    }
}

final class LearningTests: XCTestCase {
    func testLearnsSubstitution() {
        var r = Replacements()
        r.learn(typed: "open curser ai and start", corrected: "open Cursor AI and start", maxPhraseWords: 4)
        XCTAssertEqual(Set(r.entries.map(\.from)), ["curser", "ai"])
        XCTAssertEqual(Set(r.entries.map(\.to)), ["Cursor", "AI"])
        XCTAssertEqual(r.apply(to: "open curser ai and start", minCount: 1), "open Cursor AI and start")
    }
    func testIgnoresCaseOnlyInsertionsDeletions() {
        var r = Replacements()
        // Sentence-initial capitalization alone must not become a global rule.
        r.learn(typed: "hello world", corrected: "Hello world", maxPhraseWords: 4)
        r.learn(typed: "see you", corrected: "see you soon", maxPhraseWords: 4)
        r.learn(typed: "see you soon", corrected: "see you", maxPhraseWords: 4)
        XCTAssertTrue(r.entries.isEmpty)
    }
    func testRepeatIncrementsCount() {
        var r = Replacements()
        r.learn(typed: "the nandor said", corrected: "the Nandor said", maxPhraseWords: 4)
        r.learn(typed: "call nandor now", corrected: "call Nandor now", maxPhraseWords: 4)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].count, 2)
    }
    func testApplyWordBoundaryLongestFirst() {
        var r = Replacements()
        r.entries = [
            Replacement(from: "cursor", to: "Cursor", count: 1, lastTs: ""),
            Replacement(from: "cursor ai", to: "Cursor AI", count: 1, lastTs: ""),
        ]
        XCTAssertEqual(r.apply(to: "use cursor ai and precursor", minCount: 1), "use Cursor AI and precursor")
        XCTAssertEqual(r.apply(to: "Cursor rocks", minCount: 1), "Cursor rocks")
    }
    func testMinCountGate() {
        var r = Replacements()
        r.entries = [Replacement(from: "curser", to: "cursor", count: 1, lastTs: "")]
        XCTAssertEqual(r.apply(to: "open curser", minCount: 2), "open curser")
    }
    func testApplySkipsEmptyFrom() {
        var r = Replacements()
        r.entries = [Replacement(from: "   ", to: "X", count: 1, lastTs: "")]
        XCTAssertEqual(r.apply(to: "hello world", minCount: 1), "hello world")
    }
    func testInspectMissingVsCorrupt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("replacements.json")
        XCTAssertEqual(Replacements.inspect(from: url), .missing)
        try Data("{".utf8).write(to: url)
        XCTAssertEqual(Replacements.inspect(from: url), .corrupt)
        XCTAssertTrue(Replacements.load(from: url).entries.isEmpty)
    }
    func testMaxPhraseWordsClampsToOne() throws {
        let prefs = try JSONDecoder().decode(StylePrefs.self, from: Data(#"{"learning":{"maxPhraseWords":0}}"#.utf8))
        XCTAssertEqual(prefs.learning.maxPhraseWords, 1)
        var r = Replacements()
        r.learn(typed: "a b", corrected: "c d", maxPhraseWords: prefs.learning.maxPhraseWords)
        XCTAssertTrue(r.entries.isEmpty || r.entries.allSatisfy { !$0.from.isEmpty })
    }
    func testHistoryAppendLastAndCorrectionsRecent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-\(UUID().uuidString)")
        let h = dir.appendingPathComponent("history.jsonl"), rot = dir.appendingPathComponent("history.1.jsonl")
        HistoryStore.append(HistoryEntry(ts: "1", app: "A", style: "auto", raw: "a", rules: "A", out: "A", llm: false), to: h, rotated: rot)
        HistoryStore.append(HistoryEntry(ts: "2", app: "B", style: "casual", raw: "b", rules: "b", out: "b", llm: false), to: h, rotated: rot)
        XCTAssertEqual(HistoryStore.last(from: h)?.ts, "2")
        let c = dir.appendingPathComponent("corrections.jsonl")
        for i in 0..<10 { CorrectionStore.append(CorrectionEntry(ts: "\(i)", app: "A", style: "formal", typed: "t\(i)", corrected: "c\(i)"), to: c) }
        XCTAssertEqual(CorrectionStore.recent(limit: 3, from: c).map(\.ts), ["7", "8", "9"])
    }

    func testAlignmentIgnoresCaseAndPunctuation() {
        var r = Replacements()
        r.learn(typed: "so curser ai is great", corrected: "So Cursor AI is great.", maxPhraseWords: 4)
        // Key-based LCS anchors on so/So and ai/AI, so the misspelling hunk is just "curser".
        // Mid-sentence capitalization also learns ai → AI. Single-pass apply rewrites both spans.
        XCTAssertEqual(Set(r.entries.map(\.from)), ["curser", "ai"])
        XCTAssertEqual(Set(r.entries.map(\.to)), ["Cursor", "AI"])
        XCTAssertFalse(r.entries.contains { $0.from == "so curser ai" })
        XCTAssertEqual(r.apply(to: "so curser ai is great", minCount: 1), "so Cursor AI is great")
    }

    func testApplyDoesNotChain() {
        var r = Replacements()
        r.entries = [
            Replacement(from: "curser", to: "cursor", count: 1, lastTs: ""),
            Replacement(from: "cursor", to: "Cursor", count: 1, lastTs: ""),
        ]
        XCTAssertEqual(r.apply(to: "curser and cursor", minCount: 1), "cursor and Cursor")
    }

    func testLearnsMidSentenceCapitalization() {
        var r = Replacements()
        r.learn(typed: "so i use cursor and github daily", corrected: "So I use Cursor and GitHub daily.", maxPhraseWords: 4)
        XCTAssertEqual(Set(r.entries.map(\.to)), ["Cursor", "GitHub"])
        XCTAssertEqual(r.apply(to: "cursor beats github", minCount: 1), "Cursor beats GitHub")
    }
}

final class OllamaGuardrailTests: XCTestCase {
    func testRejectsMultilineAndFences() {
        XCTAssertFalse(OllamaClient.validate(input: "hello there friend", output: "Hello\nthere, friend.", glossary: []))
        XCTAssertFalse(OllamaClient.validate(input: "hello there friend", output: "```Hello there, friend.```", glossary: []))
        XCTAssertFalse(OllamaClient.validate(input: "hello there friend", output: "", glossary: []))
    }
    func testRejectsLengthDrift() {
        let input = "one two three four five six seven eight nine ten"
        XCTAssertFalse(OllamaClient.validate(input: input, output: input + " " + input, glossary: []))
        XCTAssertFalse(OllamaClient.validate(input: input, output: "one two three", glossary: []))
    }
    func testRejectsDroppedGlossaryTerm() {
        XCTAssertFalse(OllamaClient.validate(input: "open cursor ai now", output: "Open the editor now.", glossary: ["Cursor AI"]))
        XCTAssertTrue(OllamaClient.validate(input: "open cursor ai now", output: "Open Cursor AI now.", glossary: ["Cursor AI"]))
    }
    func testAcceptsCleanOutputAndSanitizesQuotes() {
        XCTAssertTrue(OllamaClient.validate(input: "hello there i think so", output: "Hello there, I think so.", glossary: []))
        XCTAssertEqual(OllamaClient.sanitize("  \"Hello.\"\n"), "Hello.")
        XCTAssertEqual(OllamaClient.sanitize("“Hello.”"), "Hello.")
    }
    func testSanitizeStripsThinkBlock() {
        XCTAssertEqual(OllamaClient.sanitize("<think>\nreasoning\n</think>\nHello there."), "Hello there.")
    }
    func testSanitizeKeepsInteriorQuotes() {
        XCTAssertEqual(OllamaClient.sanitize("\"Hello,\" she said \"bye\""), "\"Hello,\" she said \"bye\"")
        XCTAssertEqual(OllamaClient.sanitize("\"Hello there.\""), "Hello there.")
    }
    func testShortInputAcceptsSmallGrowth() {
        XCTAssertTrue(OllamaClient.validate(input: "ok", output: "Okay.", glossary: []))
        XCTAssertFalse(OllamaClient.validate(input: "ok", output: "Okay, I understand you.", glossary: []))
    }
    func testSystemPromptIncludesGlossaryAndExamples() {
        let p = OllamaClient.systemPrompt(glossary: ["Cursor AI"], examples: [CorrectionEntry(ts: "", app: "", style: "", typed: "curser", corrected: "Cursor")])
        XCTAssertTrue(p.contains("Cursor AI"))
        XCTAssertTrue(p.contains("\"curser\" -> \"Cursor\""))
        XCTAssertFalse(OllamaClient.systemPrompt(glossary: [], examples: []).contains("Always spell"))
    }
}

final class PhysicsTests: XCTestCase {
    func testDeterministicAcrossRenderRates() {
        func run(callsPerSecond: Int) -> (heat: Double, count: Int) {
            let sim = PopcornSim(seed: 12345)
            sim.allowSpawn = true
            let durationMs = 2000
            let step = max(1, 1000 / callsPerSecond)
            var mono = 0
            while mono < durationMs {
                mono += step
                let t = Double(mono) / 1000.0
                let peak: Float = sin(t * 8) > 0 ? 0.25 : 0.02
                _ = sim.advance(toMonoMs: UInt64(mono), peak: peak, peakFresh: true)
            }
            return (sim.heat, sim.kernels.count)
        }
        let a = run(callsPerSecond: 30)
        let b = run(callsPerSecond: 60)
        let c = run(callsPerSecond: 120)
        XCTAssertEqual(a.heat, b.heat, accuracy: 0.08)
        XCTAssertEqual(b.heat, c.heat, accuracy: 0.08)
        XCTAssertLessThanOrEqual(abs(a.count - c.count), 20)
        XCTAssertLessThanOrEqual(a.count, Tunables.maxKernels)
    }

    func testSameSeedSameTrajectory() {
        func heatSeries() -> [Double] {
            let sim = PopcornSim(seed: 42)
            var mono: UInt64 = 0
            var out: [Double] = []
            for i in 0..<100 {
                mono += 8
                let peak: Float = i % 10 < 5 ? 0.3 : 0.01
                out.append(sim.advance(toMonoMs: mono, peak: peak).heat)
            }
            return out
        }
        XCTAssertEqual(heatSeries(), heatSeries())
    }

    func testNoUnboundedGrowth() {
        let sim = PopcornSim(seed: 7)
        sim.allowSpawn = true
        var mono: UInt64 = 0
        var maxCount = 0
        for _ in 0..<(60 * 120) {
            mono += 8
            _ = sim.advance(toMonoMs: mono, peak: 0.4)
            maxCount = max(maxCount, sim.kernels.count)
            XCTAssertLessThanOrEqual(sim.kernels.count, Tunables.maxKernels)
        }
        XCTAssertLessThanOrEqual(maxCount, Tunables.maxKernels)
    }

    func testSettledRecycleAllowsContinuedPops() {
        let sim = PopcornSim(seed: 99)
        sim.allowSpawn = true
        var mono: UInt64 = 0
        var sawSpawnAfterHalf = false
        var countAt30s = 0
        for i in 0..<(60 * 120) {
            mono += 8
            let before = sim.kernels.filter { !$0.settled }.count
            _ = sim.advance(toMonoMs: mono, peak: 0.45)
            let after = sim.kernels.filter { !$0.settled }.count
            if i == 30 * 120 {
                countAt30s = sim.kernels.count
            }
            if i > 30 * 120, after > before {
                sawSpawnAfterHalf = true
            }
            let settled = sim.kernels.filter(\.settled).count
            XCTAssertLessThanOrEqual(settled, Tunables.maxSettledKernels)
            XCTAssertLessThanOrEqual(sim.kernels.count, Tunables.maxKernels)
        }
        XCTAssertGreaterThan(countAt30s, 0)
        XCTAssertTrue(sawSpawnAfterHalf, "expected new airborne pops after 30s of loud input")
    }

    func testInterpolationBlendsAcrossDisplayRates() {
        let sim = PopcornSim(seed: 77)
        var mono: UInt64 = 0
        while sim.kernels.filter({ !$0.settled }).isEmpty {
            mono += 8
            _ = sim.advance(toMonoMs: mono, peak: 0.2, peakFresh: true)
        }
        let id = sim.kernels.first(where: { !$0.settled })!.id
        mono += 8
        let atStep = sim.advance(toMonoMs: mono, peak: 0.2, peakFresh: false)
        guard let a = atStep.kernels.first(where: { $0.id == id }) else {
            return XCTFail("kernel vanished")
        }
        mono += 4
        let mid = sim.advance(toMonoMs: mono, peak: 0.2, peakFresh: false)
        guard let b = mid.kernels.first(where: { $0.id == id }) else {
            return XCTFail("kernel vanished mid-frame")
        }
        mono += 4
        let end = sim.advance(toMonoMs: mono, peak: 0.2, peakFresh: false)
        guard let c = end.kernels.first(where: { $0.id == id }) else {
            return XCTFail("kernel vanished at end")
        }
        let minY = min(a.y, c.y)
        let maxY = max(a.y, c.y)
        XCTAssertGreaterThanOrEqual(b.y, minY - 0.5)
        XCTAssertLessThanOrEqual(b.y, maxY + 0.5)
        let beforeIDs = Set(end.kernels.map(\.id))
        for _ in 0..<30 {
            mono += 8
            _ = sim.advance(toMonoMs: mono, peak: 0.35, peakFresh: true)
        }
        for k in sim.kernels where !beforeIDs.contains(k.id) {
            XCTAssertGreaterThan(k.y, 10)
            XCTAssertLessThan(k.x, Double(Tunables.cardW) + 40)
        }
    }

    func testDaemonStateParse() {
        XCTAssertEqual(DaemonState.parse("recording"), .recording)
        XCTAssertTrue(DaemonState.parse("transcribing").isTranscribing)
        XCTAssertTrue(DaemonState.parse("streaming").isHot)
        XCTAssertFalse(DaemonState.parse("idle").isHot)
    }
}

final class PopRewardTests: XCTestCase {
    func testVolumeIncreasesRateLaunchSpreadAndKick() {
        func run(_ peak: Float) -> (Int, Double, Double, Double) {
            let sim = PopcornSim(seed: 2026)
            var launch = 0.0, spread = 0.0, kick = 0.0
            var ids = Set<UInt64>()
            for _ in 0..<600 {
                sim.step(dt: Tunables.simDt, peak: peak)
                kick = max(kick, sim.kick)
                for k in sim.kernels where ids.insert(k.id).inserted {
                    launch += -k.vy
                    spread += abs(k.vx)
                }
            }
            return (sim.emittedCount, launch / Double(ids.count), spread / Double(ids.count), kick)
        }
        let quiet = run(0.035), normal = run(0.12), loud = run(0.28)
        XCTAssertLessThan(quiet.0, normal.0)
        XCTAssertLessThan(normal.0, loud.0)
        XCTAssertGreaterThan(loud.0, quiet.0 * 4)
        XCTAssertGreaterThan(loud.1, quiet.1 * 1.5)
        XCTAssertGreaterThan(loud.2, quiet.2)
        XCTAssertLessThan(quiet.3, 1)
        XCTAssertGreaterThan(loud.3, 3)
        XCTAssertLessThanOrEqual(loud.3, Tunables.maxKick)

        // Design envelope for the tuned launch/spread levers, accents included: nothing leaves the
        // bag faster sideways or upward than the ceiling those constants define, with a 1.5x margin
        // for the near-vertical pair impulses in `collide`, and nothing is ever non-finite.
        // `rotV` gets no upper bound on purpose: the pair pass adds `-ny * j * 0.05` with `|ny| ~ 1`
        // for exactly these collisions, so spin is not bounded by its spawn envelope and no honest
        // closed form exists. It is covered by the finiteness check below plus a tumble lower bound.
        let vxCeiling = Tunables.spreadPxPerSec
            * (Tunables.spreadHeatBase + Tunables.spreadHeatScale)
            * Tunables.burstSpreadAccent * 1.5
        let launchCeiling = (Tunables.minLaunch + Tunables.launchRange)
            * Tunables.launchJitterMax * Tunables.burstLaunchAccent * 1.5
        let env = PopcornSim(seed: 3001)
        var maxVx = 0.0, maxRot = 0.0, maxLaunch = 0.0
        var envIDs = Set<UInt64>()
        for _ in 0..<1200 {
            env.step(dt: Tunables.simDt, peak: 0.28)
            for k in env.kernels where envIDs.insert(k.id).inserted {
                XCTAssertTrue(k.vx.isFinite && k.vy.isFinite && k.rotV.isFinite)
                maxVx = max(maxVx, abs(k.vx))
                maxRot = max(maxRot, abs(k.rotV))
                maxLaunch = max(maxLaunch, -k.vy)
            }
        }
        XCTAssertGreaterThan(maxVx, 0)
        XCTAssertGreaterThan(maxLaunch, Tunables.minLaunch * 0.5)
        XCTAssertLessThanOrEqual(maxVx, vxCeiling)
        XCTAssertLessThanOrEqual(maxLaunch, launchCeiling)
        // The tuned spin range reaches the bag: kernels tumble at least as fast as `spinRange`.
        XCTAssertGreaterThan(maxRot, Tunables.spinRange)
    }

    func testQuietThresholdIsContinuousAndSilenceDoesNotPop() {
        XCTAssertLessThan(abs(Tunables.popsPerSecond(heat: 0.0799)
            - Tunables.popsPerSecond(heat: 0.0801)), 0.01)
        let sim = PopcornSim(seed: 1)
        for _ in 0..<1200 { sim.step(dt: Tunables.simDt, peak: 0) }
        XCTAssertEqual(sim.emittedCount, 0)
    }

    func testPopsPerSecondMatchesVoiceBands() {
        XCTAssertEqual(Tunables.popsPerSecond(heat: 0), 0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(Tunables.popsPerSecond(heat: 0.25), Tunables.quietPopsPerSec)
        XCTAssertLessThanOrEqual(Tunables.popsPerSecond(heat: 0.32), Tunables.quietPopsPerSecMax + 0.1)
        XCTAssertGreaterThanOrEqual(Tunables.popsPerSecond(heat: 0.55), Tunables.speechPopsPerSecMin - 1)
        XCTAssertLessThanOrEqual(Tunables.popsPerSecond(heat: 0.68), Tunables.speechPopsPerSecMax + 0.1)
        XCTAssertGreaterThanOrEqual(Tunables.popsPerSecond(heat: 0.9), Tunables.loudPopsPerSecMin - 1)
        XCTAssertEqual(Tunables.popsPerSecond(heat: 1), Tunables.ceilingPopsPerSec, accuracy: 0.01)
        // The tuned curve must stay monotone: louder never means fewer pops.
        var previous = -1.0
        for i in 0...200 {
            let value = Tunables.popsPerSecond(heat: Double(i) / 200)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertTrue(value.isFinite)
            previous = value
        }
    }

    func testOnsetCascadesAreSpacedAndDoNotRepeatOnHold() {
        let sim = PopcornSim(seed: 2)
        var times: [Double] = []
        for i in 0..<120 {
            let before = sim.emittedCount
            sim.step(dt: Tunables.simDt, peak: 0.28)
            if sim.emittedCount > before { times.append(Double(i) * Tunables.simDt) }
        }
        XCTAssertGreaterThanOrEqual(times.filter { $0 < 0.1 }.count, 4)
        XCTAssertGreaterThan(Set(times.prefix(4)).count, 1)
        let before = sim.emittedCount
        for _ in 0..<120 { sim.step(dt: Tunables.simDt, peak: 0.28) }
        // A held level re-triggers no onset burst: one more second of saturated heat emits the
        // design ceiling rate and nothing extra. (Accuracy 1 covers the sub-pop accumulator phase
        // carried in from the previous second.)
        XCTAssertEqual(Double(sim.emittedCount - before), Tunables.ceilingPopsPerSec, accuracy: 1)
        // …and the emitter never hit the capacity clamp, which would silently depress the count
        // above instead of failing.
        XCTAssertLessThan(sim.kernels.count, Tunables.maxKernels)
    }

    func testMoodLagsHeat() {
        let sim = PopcornSim(seed: 5)
        for _ in 0..<24 { sim.step(dt: Tunables.simDt, peak: 0.28) }   // 200 ms of loud speech
        XCTAssertGreaterThan(sim.heat, 0.9)
        XCTAssertLessThan(sim.mood, sim.heat)                            // still lags heat
        XCTAssertGreaterThan(sim.mood, 0.5)                              // …but answers fast
        let peakMood = sim.mood
        for _ in 0..<60 { sim.step(dt: Tunables.simDt, peak: 0) }       // 500 ms of silence
        XCTAssertLessThan(sim.heat, 0.05)
        XCTAssertGreaterThan(sim.mood, sim.heat + 0.2)                   // slow release
        // Afterglow: the expression is still most of the way up half a second into silence.
        XCTAssertGreaterThan(sim.mood, peakMood * 0.45)
        XCTAssertEqual(sim.advance(toMonoMs: 1, peak: 0).mood, sim.mood)
    }

    func testRecoilRecoversAfterBurst() {
        let sim = PopcornSim(seed: 11)
        for _ in 0..<5 { sim.step(dt: Tunables.simDt, peak: 0.28) }
        XCTAssertGreaterThan(sim.kick, 0.5)
        sim.allowSpawn = false
        for _ in 0..<240 { sim.step(dt: Tunables.simDt, peak: 0) }
        XCTAssertLessThan(abs(sim.kick), 0.15)
        XCTAssertLessThan(abs(sim.kickV), 5)
    }

    func testFlightApexDescentSettleAndCleanup() {
        let sim = PopcornSim(seed: 8)
        while sim.kernels.isEmpty { sim.step(dt: Tunables.simDt, peak: 0.12) }
        let first = sim.kernels[0]
        sim.allowSpawn = false
        var rising = false, falling = false, settled = false, fading = false
        var minimumY = first.y
        for _ in 0..<600 {
            sim.step(dt: Tunables.simDt, peak: 0)
            if let k = sim.kernels.first(where: { $0.id == first.id }) {
                rising = rising || k.vy < 0
                falling = falling || k.vy > 0
                settled = settled || k.settled
                fading = fading || k.alpha < 1
                minimumY = min(minimumY, k.y)
                if k.life < k.maxLife - Tunables.cleanupFade { XCTAssertEqual(k.alpha, 1) }
                XCTAssertEqual(k.front, first.front)
                XCTAssertTrue(k.x.isFinite && k.y.isFinite && k.vx.isFinite && k.rotV.isFinite)
            }
        }
        XCTAssertTrue(rising && falling && settled && fading)
        XCTAssertLessThan(minimumY, first.y - 20)
        XCTAssertGreaterThan(minimumY, 10)
        XCTAssertTrue(sim.kernels.isEmpty)
    }

    func testUnavailableStopAndReduceMotionCancelQueuedPops() {
        for mode in 0..<3 {
            let sim = PopcornSim(seed: 4)
            for _ in 0..<3 { sim.step(dt: Tunables.simDt, peak: 0.28) }
            let emitted = sim.emittedCount
            switch mode {
            case 0: sim.allowSpawn = false
            case 1: sim.levelsUnavailable = true
            default: sim.reduceMotion = true
            }
            for _ in 0..<120 { sim.step(dt: Tunables.simDt, peak: 0.28) }
            XCTAssertEqual(sim.emittedCount, emitted)
            if mode == 2 {
                XCTAssertTrue(sim.kernels.allSatisfy(\.settled))
                XCTAssertEqual(sim.kick, 0)
                sim.reduceMotion = false
                sim.step(dt: Tunables.simDt, peak: 0.28)
                XCTAssertEqual(sim.emittedCount, emitted)
            }
        }
    }

    func testSameSeedMatchesFullBodiesAndInvalidInputStaysFinite() {
        let a = PopcornSim(seed: 44), b = PopcornSim(seed: 44)
        for i in 0..<600 {
            let peak: Float = i % 60 < 30 ? 0.28 : 0.035
            a.step(dt: Tunables.simDt, peak: peak)
            b.step(dt: Tunables.simDt, peak: peak)
            XCTAssertEqual(a.kernels, b.kernels)
        }
        a.step(dt: Tunables.simDt, peak: .nan)
        a.step(dt: Tunables.simDt, peak: .infinity)
        XCTAssertTrue(a.heat.isFinite)
    }

    func testKernelArtCachedAndAsymmetric() {
        let a = KernelArt.path(shape: 0)
        let b = KernelArt.path(shape: 0)
        XCTAssertTrue(a === b)
        for shape in 0..<KernelArt.templateCount {
            let box = KernelArt.path(shape: shape).boundingBox
            let aspect = box.width / max(0.01, box.height)
            XCTAssertGreaterThan(aspect, 0.55)
            XCTAssertLessThan(aspect, 1.75)
            XCTAssertFalse(KernelArt.creases(shape: shape).isEmpty)
        }
    }

    func testKernelArtHullAndLobesCached() {
        let h0 = KernelArt.hull(shape: 0)
        let h1 = KernelArt.hull(shape: 0)
        XCTAssertTrue(h0 === h1)
        XCTAssertFalse(h0.isEmpty)
        for shape in 0..<KernelArt.templateCount {
            let lobes = KernelArt.lobes(shape: shape)
            XCTAssertFalse(lobes.isEmpty)
            XCTAssertGreaterThanOrEqual(lobes.count, 3)
            let hullBox = KernelArt.hull(shape: shape).boundingBox
            XCTAssertGreaterThan(hullBox.width, 0.05)
            XCTAssertLessThan(hullBox.width, 0.45)
            // Same shape returns identical lobe arrays.
            XCTAssertEqual(KernelArt.lobes(shape: shape), lobes)
        }
    }
}
