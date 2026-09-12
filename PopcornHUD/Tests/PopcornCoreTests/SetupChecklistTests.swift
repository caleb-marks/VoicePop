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
        list.observePracticeText("hello there")
        XCTAssertTrue(list.state(of: .permissions).isDone)
        XCTAssertTrue(list.isComplete)
    }

    func testWhitespacePracticeTextIsNotEvidence() {
        var list = SetupChecklist(engine: .done("ok"), model: .done("ok"))
        list.observePracticeText("  \n")
        XCTAssertFalse(list.evidence.practiceInsertionObserved)
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
}
