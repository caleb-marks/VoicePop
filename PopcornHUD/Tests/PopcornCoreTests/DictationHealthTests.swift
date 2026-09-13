import XCTest
@testable import PopcornCore

final class DictationStatusTests: XCTestCase {
    private let ready = EngineFacts(engineInstalled: true, modelInstalled: true, modelTitle: "Parakeet")

    func testReadyOnlyWhenNothingBlocks() {
        let s = DictationStatus(daemon: .idle, facts: ready)
        XCTAssertNil(s.issue)
        XCTAssertTrue(s.canDictate)
        XCTAssertEqual(s.headline, "Ready · Hold FN to dictate")
        XCTAssertNil(s.detail)
        XCTAssertEqual(s.actions, [])
        // Unknown model state stays optimistic rather than alarming.
        XCTAssertNil(DictationStatus(daemon: .idle, facts: EngineFacts()).issue)
    }

    func testPriorityOrderAndNeverReadyWhenBlocked() {
        var f = ready
        f.engineInstalled = false
        f.download = .init(model: "small.en", fraction: 0.5)
        f.modelInstalled = false
        f.permissionsNeeded = true
        f.lastFailure = DictationFailure.noText.rawValue
        let order: [(DictationIssue, (inout EngineFacts) -> Void)] = [
            (.engineNotInstalled, { $0.engineInstalled = true }),
            (.modelDownloading(fraction: 0.5), { $0.download = nil }),
            (.modelMissing, { $0.modelInstalled = true }),
        ]
        for (expected, fix) in order {
            let s = DictationStatus(daemon: .missing, facts: f)
            XCTAssertEqual(s.issue, expected)
            XCTAssertFalse(s.canDictate)
            XCTAssertFalse(s.headline.hasPrefix("Ready"), s.headline)
            fix(&f)
        }
        XCTAssertEqual(DictationStatus(daemon: .missing, facts: f).issue, .engineNotRunning)
        XCTAssertEqual(DictationStatus(daemon: .idle, facts: f).issue, .permissionsNeeded)
        f.permissionsNeeded = false
        XCTAssertEqual(DictationStatus(daemon: .idle, facts: f).issue, .lastDictationFailed(DictationFailure.noText.rawValue))
        XCTAssertNil(DictationStatus(daemon: .recording, facts: f).issue, "a past failure is not shown while recording")
        f.audioLevelsUnavailable = true
        XCTAssertEqual(DictationStatus(daemon: .recording, facts: f).issue, .audioLevelsUnavailable)
        XCTAssertNil(DictationStatus(daemon: .idle, facts: EngineFacts(audioLevelsUnavailable: true)).issue,
                     "levels only matter while recording")
    }

    func testBlockingIssuesCannotDictateButSoftIssuesCan() {
        var f = ready
        f.permissionsNeeded = true
        XCTAssertFalse(DictationStatus(daemon: .idle, facts: f).canDictate)
        f.permissionsNeeded = false
        f.lastFailure = "Something odd"
        XCTAssertTrue(DictationStatus(daemon: .idle, facts: f).canDictate)
        f.lastFailure = nil
        f.audioLevelsUnavailable = true
        XCTAssertTrue(DictationStatus(daemon: .recording, facts: f).canDictate)
    }

    func testHeadlinesDetailsAndActionsPerIssue() {
        func status(_ daemon: DaemonState = .idle, _ change: (inout EngineFacts) -> Void) -> DictationStatus {
            var f = ready
            change(&f)
            return DictationStatus(daemon: daemon, facts: f)
        }
        var s = status { $0.engineInstalled = false; $0.engineProblem = "This Voxtype build can’t run Parakeet." }
        XCTAssertEqual(s.headline, "Speech engine not installed")
        XCTAssertEqual(s.detail, "This Voxtype build can’t run Parakeet.")
        XCTAssertEqual(s.actions, [.openSetup])

        s = status { $0.download = .init(model: "small.en", fraction: 0.426) }
        XCTAssertEqual(s.headline, "Downloading speech model… 43%")
        XCTAssertEqual(s.actions, [.openSettings])
        XCTAssertEqual(status { $0.download = .init(model: "x", fraction: nil) }.headline, "Downloading speech model…")

        s = status { $0.modelInstalled = false }
        XCTAssertEqual(s.headline, "Speech model not installed")
        XCTAssertEqual(s.detail, "Download “Parakeet” or choose another model.")
        XCTAssertEqual(s.actions, [.openSetup])

        s = status(.missing) { _ in }
        XCTAssertEqual(s.headline, "Dictation isn’t running")
        XCTAssertEqual(s.actions, [.restartEngine, .openSetup])

        s = status { $0.permissionsNeeded = true }
        XCTAssertEqual(s.headline, "Voxtype needs permission")
        XCTAssertEqual(s.actions, [.openPrivacySettings, .openSetup])
        s = status { $0.permissionsNeeded = true; $0.permissionHint = .microphone }
        XCTAssertEqual(s.headline, "Voxtype can’t hear the microphone")
        XCTAssertTrue(s.detail!.contains("Microphone"))

        for failure in DictationFailure.allCases {
            s = status { $0.lastFailure = failure.rawValue }
            XCTAssertEqual(s.headline, failure.rawValue)
            XCTAssertNotNil(s.detail)
            XCTAssertEqual(s.actions, [.restartEngine], "no new text exists to copy after \(failure)")
            XCTAssertFalse(s.headline.lowercased().contains("inserted"))
        }
        s = status { $0.lastFailure = "Voxtype reported an error" }
        XCTAssertEqual(s.headline, "Last dictation didn’t finish")
        XCTAssertEqual(s.actions, [.copyLastText, .restartEngine])

        s = status(.recording) { $0.audioLevelsUnavailable = true }
        XCTAssertEqual(s.headline, "Recording…")
        XCTAssertEqual(s.actions, [.restartEngine])
        XCTAssertEqual(status(.transcribing) { _ in }.headline, "Transcribing…")
    }
}

final class DictationSessionTrackerTests: XCTestCase {
    private func tracker(signal: Bool = true) -> DictationSessionTracker {
        var t = DictationSessionTracker(transcriptSignalExpected: signal)
        t.stateChanged(.idle, atMs: 0)
        return t
    }

    func testSuccessfulDictationLeavesNoFailure() {
        var t = tracker()
        t.stateChanged(.recording, atMs: 1000)
        t.stateChanged(.transcribing, atMs: 4000)
        t.transcriptReady(atMs: 4200)
        t.stateChanged(.idle, atMs: 4201)
        t.tick(atMs: 10_000)
        XCTAssertNil(t.failure)
        XCTAssertNil(t.nextDeadlineMs)
    }

    func testTranscriptSignalMayArriveJustAfterIdle() {
        var t = tracker()
        t.stateChanged(.recording, atMs: 1000)
        t.stateChanged(.transcribing, atMs: 4000)
        t.stateChanged(.idle, atMs: 4100)
        XCTAssertEqual(t.nextDeadlineMs, 4850)
        t.transcriptReady(atMs: 4102)
        t.tick(atMs: 5000)
        XCTAssertNil(t.failure)
    }

    func testNoTextAfterGraceButNotForTapsCancelsOrUnknownPostProcess() {
        var t = tracker()
        t.stateChanged(.recording, atMs: 1000)
        t.stateChanged(.transcribing, atMs: 3000)
        t.stateChanged(.idle, atMs: 3100)
        t.tick(atMs: 3849)
        XCTAssertNil(t.failure)
        t.tick(atMs: 3850)
        XCTAssertEqual(t.failure, .noText)
        // The next successful dictation clears it.
        t.stateChanged(.recording, atMs: 5000)
        t.stateChanged(.transcribing, atMs: 7000)
        t.transcriptReady(atMs: 7100)
        XCTAssertNil(t.failure)

        var tap = tracker()
        tap.stateChanged(.recording, atMs: 1000)
        tap.stateChanged(.transcribing, atMs: 1400)
        tap.stateChanged(.idle, atMs: 1500)
        tap.tick(atMs: 9000)
        XCTAssertNil(tap.failure, "sub-second taps are accidental")

        var cancel = tracker()
        cancel.stateChanged(.recording, atMs: 1000)
        cancel.stateChanged(.idle, atMs: 5000)
        cancel.tick(atMs: 9000)
        XCTAssertNil(cancel.failure, "recording → idle is a cancel")

        var unknown = tracker(signal: false)
        unknown.stateChanged(.recording, atMs: 1000)
        unknown.stateChanged(.transcribing, atMs: 4000)
        unknown.stateChanged(.idle, atMs: 4100)
        unknown.tick(atMs: 9000)
        XCTAssertNil(unknown.failure, "without voxtype-clean there is no transcript signal to miss")
    }

    func testRecordRequestWithoutRecordingState() {
        var t = tracker()
        t.recordRequested(start: true, atMs: 100)
        XCTAssertEqual(t.nextDeadlineMs, 3100)
        t.tick(atMs: 3099)
        XCTAssertNil(t.failure)
        t.tick(atMs: 3100)
        XCTAssertEqual(t.failure, .didNotStart)
        t.recordRequested(start: true, atMs: 4000)
        t.stateChanged(.recording, atMs: 4050)
        XCTAssertNil(t.failure)
        XCTAssertNil(t.nextDeadlineMs)

        var stopRequest = tracker()
        stopRequest.stateChanged(.recording, atMs: 0)
        stopRequest.recordRequested(start: true, atMs: 100)
        stopRequest.tick(atMs: 10_000)
        XCTAssertNil(stopRequest.failure, "a toggle while recording is a stop, not a start")
    }

    func testStuckTranscriptionAndDaemonExit() {
        var t = tracker()
        t.stateChanged(.recording, atMs: 0)
        t.stateChanged(.transcribing, atMs: 2000)
        XCTAssertEqual(t.nextDeadlineMs, 22_000)
        t.tick(atMs: 22_000)
        XCTAssertEqual(t.failure, .transcriptionStuck)
        XCTAssertNil(t.nextDeadlineMs)
        t.transcriptReady(atMs: 23_000)
        t.stateChanged(.idle, atMs: 23_001)
        XCTAssertNil(t.failure)

        t.stateChanged(.recording, atMs: 30_000)
        t.stateChanged(.missing, atMs: 31_000)
        XCTAssertEqual(t.failure, .stoppedUnexpectedly)
        t.stateChanged(.idle, atMs: 40_000)
        t.stateChanged(.recording, atMs: 41_000)
        t.stateChanged(.transcribing, atMs: 43_000)
        t.transcriptReady(atMs: 43_100)
        XCTAssertNil(t.failure)
    }

    func testRapidStartStopCancelSequencesStayConsistent() {
        var t = tracker()
        var now: UInt64 = 0
        let sequence: [DaemonState] = [.recording, .idle, .recording, .transcribing, .recording, .idle, .recording, .transcribing, .idle]
        for s in sequence {
            now += 40
            t.stateChanged(s, atMs: now)
        }
        t.tick(atMs: now + 5000)
        XCTAssertNil(t.failure, "every recording here is shorter than the evidence threshold")
        XCTAssertNil(t.nextDeadlineMs)
    }

    func testMicrophoneSilenceNeedsRepeatedEvidence() {
        var t = tracker()
        t.recordingLevels(frames: 300, maxPeak: 0, durationMs: 3000)
        XCTAssertFalse(t.microphoneSilent)
        t.recordingLevels(frames: 5, maxPeak: 0, durationMs: 3000) // too few frames: no evidence either way
        t.recordingLevels(frames: 300, maxPeak: 0, durationMs: 1000) // too short
        XCTAssertFalse(t.microphoneSilent)
        t.recordingLevels(frames: 300, maxPeak: 0, durationMs: 2500)
        XCTAssertTrue(t.microphoneSilent)
        t.recordingLevels(frames: 300, maxPeak: 0.0001, durationMs: 2500)
        XCTAssertFalse(t.microphoneSilent, "any real signal clears the hint")
        t.recordingLevels(frames: 300, maxPeak: 0, durationMs: 2500)
        t.recordingLevels(frames: 300, maxPeak: 0, durationMs: 2500)
        XCTAssertTrue(t.microphoneSilent)
        t.transcriptReady(atMs: 1)
        XCTAssertFalse(t.microphoneSilent)
    }
}

final class EngineProbeResultTests: XCTestCase {
    private let catalog: [String: [String: Bool]] = [
        "parakeet": ["parakeet-tdt-0.6b-v3": false, "parakeet-tdt-0.6b-v3-int8": true],
        "whisper": ["small.en": true, "medium.en": false],
    ]

    func testPrepackedLocalVariantCountsAsInstalled() {
        // The configured name is not in Voxtype's catalog but is a local variant of an installed model.
        let r = EngineProbeResult(binaryInstalled: true, configuredEngine: "parakeet", compiledEngines: ["parakeet": true],
                                  configuredModel: "parakeet-tdt-0.6b-v3-int8-prepacked", catalog: catalog)
        XCTAssertEqual(r.modelInstalled, true)
        XCTAssertTrue(r.engineUsable)
    }

    func testKnownCatalogModelNotInstalled() {
        let r = EngineProbeResult(binaryInstalled: true, configuredEngine: "whisper", configuredModel: "medium.en",
                                  catalog: catalog, localModelEntries: ["ggml-small.en.bin"])
        XCTAssertEqual(r.modelInstalled, false)
        XCTAssertEqual(EngineProbeResult(binaryInstalled: true, configuredEngine: "whisper", configuredModel: "small.en",
                                         catalog: [:], localModelEntries: ["ggml-small.en.bin"]).modelInstalled, true)
    }

    func testUnknownStaysUnknown() {
        XCTAssertNil(EngineProbeResult(binaryInstalled: true, configuredModel: "custom-model", catalog: catalog).modelInstalled)
        XCTAssertNil(EngineProbeResult(binaryInstalled: true).modelInstalled)
        XCTAssertNil(EngineProbeResult(binaryInstalled: true, configuredModel: "/models/x.bin").modelInstalled)
        XCTAssertEqual(EngineProbeResult(binaryInstalled: true, configuredModel: "/models/x.bin", configuredModelPathExists: false).modelInstalled, false)
    }

    func testEngineNotCompiledIsUnusable() {
        XCTAssertFalse(EngineProbeResult(binaryInstalled: false).engineUsable)
        XCTAssertFalse(EngineProbeResult(binaryInstalled: true, configuredEngine: "parakeet", compiledEngines: ["parakeet": false]).engineUsable)
        XCTAssertTrue(EngineProbeResult(binaryInstalled: true, configuredEngine: "parakeet").engineUsable, "unknown compile state stays optimistic")
    }
}

final class VoxtypeConfigScanTests: XCTestCase {
    func testFindsPostProcessCommandOnlyInItsSection() {
        let toml = """
        engine = "parakeet"
        [output]
        command = "not-this"
        [output.post_process]
        # command = "/old/voxtype-clean"
        command = "/Users/example/VoicePop/bin/voxtype-clean"   # trailing comment
        timeout_ms = 5000
        [vad]
        command = "nope"
        """
        XCTAssertEqual(VoxtypeConfigScan.postProcessCommand(in: toml), "/Users/example/VoicePop/bin/voxtype-clean")
        XCTAssertNil(VoxtypeConfigScan.postProcessCommand(in: "[output.post_process]\n# command = \"x\"\n"))
        XCTAssertNil(VoxtypeConfigScan.postProcessCommand(in: "engine = \"whisper\"\n"))
    }
}
