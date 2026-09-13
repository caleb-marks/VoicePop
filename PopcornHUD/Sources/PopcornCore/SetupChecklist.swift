import Foundation

/// The first-run and recovery checklist, as pure state. The window renders it; probes and user
/// actions feed it. Engine and model are always re-derived from the machine; the steps that
/// macOS will not let VoicePop inspect directly (permissions, the FN key, practice) complete only
/// on functional evidence and are remembered so an interrupted setup resumes where it stopped.
public struct SetupChecklist: Equatable, Sendable {
    public enum Step: String, CaseIterable, Codable, Sendable {
        case engine, model, permissions, fnKey, practice
    }

    public enum StepState: Equatable, Sendable {
        case pending
        /// Long-running work; fraction when progress is reported.
        case working(message: String, fraction: Double?)
        case needsAction(String)
        case failed(String)
        case done(String)

        public var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    /// Evidence gathered since setup began. Only `true` values are persisted.
    public struct Evidence: Codable, Equatable, Sendable {
        /// A recording state was observed after the user was asked to hold FN: the hotkey reached
        /// Voxtype, so Input Monitoring works and the Globe key is not swallowed by macOS.
        public var fnRecordingObserved = false
        /// Voxtype produced a transcript (microphone access works).
        public var transcriptObserved = false
        /// Dictated text arrived in VoicePop's own practice field (Accessibility typing works).
        public var practiceInsertionObserved = false

        public init(fnRecordingObserved: Bool = false, transcriptObserved: Bool = false, practiceInsertionObserved: Bool = false) {
            self.fnRecordingObserved = fnRecordingObserved
            self.transcriptObserved = transcriptObserved
            self.practiceInsertionObserved = practiceInsertionObserved
        }
    }

    public var engine: StepState = .pending
    public var model: StepState = .pending
    public var evidence = Evidence()

    public init(engine: StepState = .pending, model: StepState = .pending, evidence: Evidence = Evidence()) {
        self.engine = engine
        self.model = model
        self.evidence = evidence
    }

    public func state(of step: Step) -> StepState {
        switch step {
        case .engine: return engine
        case .model:
            if !engine.isDone, model == .pending { return .pending }
            return model
        case .permissions:
            if evidence.practiceInsertionObserved {
                return .done("Voxtype can hear you and type for you.")
            }
            if evidence.transcriptObserved || evidence.fnRecordingObserved {
                return .needsAction("Voxtype is listening. Finish the practice below to confirm it can type.")
            }
            return .needsAction("Turn on Voxtype in Accessibility, Input Monitoring, and Microphone.")
        case .fnKey:
            if evidence.fnRecordingObserved { return .done("Holding FN starts dictation.") }
            return .needsAction("Set “Press 🌐 key to” Do Nothing, then hold FN.")
        case .practice:
            if evidence.practiceInsertionObserved { return .done("Practice dictation typed into VoicePop.") }
            if !engine.isDone || !model.isDone { return .pending }
            return .needsAction("Click the practice field, hold FN, say a few words, and release.")
        }
    }

    /// Engine and model are installed, so dictation services can start.
    public var servicesReady: Bool { engine.isDone && model.isDone }

    public var isComplete: Bool { Step.allCases.allSatisfy { state(of: $0).isDone } }

    public var completedCount: Int { Step.allCases.filter { state(of: $0).isDone }.count }

    // MARK: Evidence from observed daemon activity

    /// Feed every daemon state transition while the checklist is open.
    public mutating func observe(daemon: DaemonState) {
        if daemon.isHot { evidence.fnRecordingObserved = true }
    }

    /// Voxtype's post-processor finished a transcript.
    public mutating func observeTranscript() {
        evidence.transcriptObserved = true
    }

    /// How soon after a transcript text must arrive to count as dictated rather than typed by hand.
    public static let practiceInsertionWindow: TimeInterval = 5

    /// Text changed in the practice field. It counts as evidence only when non-blank and it follows
    /// a transcript within `practiceInsertionWindow` seconds (`secondsSinceTranscript`), so typing
    /// into the field by hand cannot mark permissions complete.
    public mutating func observePracticeText(_ text: String, secondsSinceTranscript: TimeInterval?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let age = secondsSinceTranscript, age >= 0, age <= Self.practiceInsertionWindow
        else { return }
        evidence.practiceInsertionObserved = true
        // Typed text can only come from a completed recording and transcript.
        evidence.transcriptObserved = true
        evidence.fnRecordingObserved = true
    }
}

/// Persists checklist evidence so interrupted setup resumes. Injectable for tests.
public struct SetupEvidenceStore {
    public static let defaultsKey = "setupChecklistEvidence"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SetupChecklist.Evidence {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let evidence = try? JSONDecoder().decode(SetupChecklist.Evidence.self, from: data)
        else { return SetupChecklist.Evidence() }
        return evidence
    }

    public func save(_ evidence: SetupChecklist.Evidence) {
        guard let data = try? JSONEncoder().encode(evidence) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
