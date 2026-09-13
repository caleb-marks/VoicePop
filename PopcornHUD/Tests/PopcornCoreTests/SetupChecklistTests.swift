import XCTest
@testable import PopcornCore

final class SetupChecklistTests: XCTestCase {
    func testPermissionsNeverCompleteWithoutInsertionEvidence() {
        var list = SetupChecklist(engine: .done("ok"), model: .done("ok"))
        XCTAssertFalse(list.state(of: .permissions).isDone)
        list.observe(daemon: .recording)
        list.observeTranscript()
        XCTAssertTrue(list.state(of: .fnKey).isDone)
        XCTAssertFalse(list.state(of: .permissions).isDone, "recording + transcript does not prove typing works")
        XCTAssertFalse(list.isComplete)
        list.observePracticeText("hello there", secondsSinceTranscript: 0.8)
        XCTAssertTrue(list.state(of: .permissions).isDone)
        XCTAssertTrue(list.isComplete)
    }

    func testWhitespacePracticeTextIsNotEvidence() {
        var list = SetupChecklist(engine: .done("ok"), model: .done("ok"))
        list.observePracticeText("  \n", secondsSinceTranscript: 0.5)
        XCTAssertFalse(list.evidence.practiceInsertionObserved)
    }

    func testHandTypedPracticeTextIsNotEvidence() {
        var list = SetupChecklist(engine: .done("ok"), model: .done("ok"))
        list.observePracticeText("typed by hand", secondsSinceTranscript: nil)
        XCTAssertFalse(list.evidence.practiceInsertionObserved)
        list.observeTranscript()
        list.observePracticeText("typed much later", secondsSinceTranscript: 60)
        XCTAssertFalse(list.state(of: .permissions).isDone)
    }

    func testIdleOrTranscribingStateIsNotFnEvidence() {
        var list = SetupChecklist()
        list.observe(daemon: .idle)
        list.observe(daemon: .transcribing)
        list.observe(daemon: .missing)
        XCTAssertFalse(list.state(of: .fnKey).isDone)
    }

    func testPracticeWaitsForEngineAndModel() {
        var list = SetupChecklist(engine: .done("ok"), model: .working(message: "Downloading", fraction: 0.3))
        XCTAssertEqual(list.state(of: .practice), .pending)
        XCTAssertFalse(list.servicesReady)
        list.model = .done("ok")
        XCTAssertTrue(list.servicesReady)
        if case .needsAction = list.state(of: .practice) {} else { XCTFail("practice should be actionable") }
    }

    func testEvidencePersistsAcrossInterruptions() {
        let suite = "SetupChecklistTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SetupEvidenceStore(defaults: defaults)
        XCTAssertEqual(store.load(), SetupChecklist.Evidence())
        var list = SetupChecklist()
        list.observe(daemon: .recording)
        store.save(list.evidence)
        let resumed = SetupChecklist(evidence: store.load())
        XCTAssertTrue(resumed.state(of: .fnKey).isDone)
        XCTAssertFalse(resumed.state(of: .engine).isDone, "engine is re-derived, never persisted")
        store.reset()
        XCTAssertEqual(store.load(), SetupChecklist.Evidence())
    }

    func testOnlyPermissionEvidenceMakesEarlierSuccessStale() {
        var list = SetupChecklist(engine: .done("ok"), model: .done("ok"))
        list.observeTranscript()
        list.observePracticeText("hello", secondsSinceTranscript: 1)
        XCTAssertTrue(list.isComplete)

        XCTAssertFalse(list.invalidateEvidence(issue: nil))
        XCTAssertFalse(list.invalidateEvidence(issue: .lastDictationFailed(DictationFailure.noText.rawValue)),
                       "an empty dictation is usually silence, not a revoked permission")
        XCTAssertTrue(list.isComplete)

        XCTAssertTrue(list.invalidateEvidence(issue: .permissionsNeeded))
        XCTAssertFalse(list.state(of: .permissions).isDone)
        XCTAssertTrue(list.state(of: .fnKey).isDone, "microphone evidence says nothing about the FN key")

        list.observePracticeText("again", secondsSinceTranscript: 1)
        list.engineReinstalled()
        XCTAssertEqual(list.evidence, SetupChecklist.Evidence())
    }
}
