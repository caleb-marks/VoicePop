import Foundation

/// Failures VoicePop can distinguish from the outside. Wording is neutral: VoicePop cannot see
/// whether text reached the focused app, so nothing here claims or denies insertion.
public enum DictationFailure: String, CaseIterable, Sendable {
    /// A recording request (menu) produced no recording state.
    case didNotStart = "Recording didn’t start"
    /// Recording ended, transcription finished, and no text came back (silence, VAD, or failure).
    case noText = "No text came back from the last dictation"
    /// Still transcribing long after any normal utterance would have finished.
    case transcriptionStuck = "Transcription is taking longer than usual"
    /// The daemon exited while recording or transcribing.
    case stoppedUnexpectedly = "Dictation stopped unexpectedly"
}

/// Turns observable dictation events into failure/permission evidence. Pure and clock-injected;
/// `DictationHealthMonitor` feeds it on main and arms one timer at `nextDeadlineMs`.
public struct DictationSessionTracker: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var startTimeoutMs: UInt64 = 3000
        public var transcribeTimeoutMs: UInt64 = 20_000
        /// The transcript-ready signal and the daemon's return to idle race (typing can take <1 ms),
        /// so "no text" is only concluded this long after idle.
        public var transcriptGraceMs: UInt64 = 750
        /// Shorter recordings are treated as accidental taps and never produce evidence.
        public var minEvidenceRecordingMs: UInt64 = 1000
        /// Recordings this long with frames but an exact-zero peak count as silent input.
        public var minSilentRecordingMs: UInt64 = 1500
        public var minSilentFrames = 20
        public var silentRecordingsForMicrophoneHint = 2
        public init() {}
    }

    public var config: Config
    /// True only when Voxtype's post-process command is voxtype-clean, i.e. a successful
    /// transcription would post the transcript-ready signal. Without it "no text" is undetectable.
    public var transcriptSignalExpected: Bool

    public private(set) var failure: DictationFailure?
    /// Evidence (not proof) that Voxtype receives silence from the microphone, as macOS delivers
    /// when microphone access is denied. Cleared by any audible recording or transcript.
    public private(set) var microphoneSilent = false

    private var state: DaemonState = .missing
    private var pendingStartMs: UInt64?
    private var recordingStartMs: UInt64?
    private var recordingDurationMs: UInt64 = 0
    private var transcribingSinceMs: UInt64?
    private var transcriptSinceRecording = false
    private var noTextCheckMs: UInt64?
    private var silentStreak = 0

    public init(config: Config = Config(), transcriptSignalExpected: Bool = false) {
        self.config = config
        self.transcriptSignalExpected = transcriptSignalExpected
    }

    public var nextDeadlineMs: UInt64? {
        let start = pendingStartMs.map { $0 + config.startTimeoutMs }
        let stuck = failure == .transcriptionStuck ? nil : transcribingSinceMs.map { $0 + config.transcribeTimeoutMs }
        return [start, stuck, noTextCheckMs].compactMap { $0 }.min()
    }

    public mutating func recordRequested(start: Bool, atMs now: UInt64) {
        guard start, state == .idle else { return }
        pendingStartMs = now
    }

    public mutating func stateChanged(_ next: DaemonState, atMs now: UInt64) {
        let previous = state
        guard next != previous else { return }
        state = next
        if next.isHot {
            pendingStartMs = nil
            if !previous.isHot {
                recordingStartMs = now
                transcriptSinceRecording = false
                transcribingSinceMs = nil
                noTextCheckMs = nil
                if failure == .didNotStart || failure == .transcriptionStuck { failure = nil }
            }
            return
        }
        if previous.isHot {
            recordingDurationMs = recordingStartMs.map { now >= $0 ? now - $0 : 0 } ?? 0
            recordingStartMs = nil
        }
        switch next {
        case .transcribing:
            transcribingSinceMs = now
        case .idle:
            // recording → idle directly is a cancel; only a finished transcription can lack text.
            if previous.isTranscribing, transcriptSignalExpected, !transcriptSinceRecording,
               recordingDurationMs >= config.minEvidenceRecordingMs {
                noTextCheckMs = now + config.transcriptGraceMs
            }
            if previous.isTranscribing, failure == .transcriptionStuck {
                failure = nil
            }
            transcribingSinceMs = nil
        case .missing:
            if previous.isHot || previous.isTranscribing { failure = .stoppedUnexpectedly }
            pendingStartMs = nil
            transcribingSinceMs = nil
        default:
            break
        }
    }

    public mutating func transcriptReady(atMs now: UInt64) {
        transcriptSinceRecording = true
        noTextCheckMs = nil
        failure = nil
        silentStreak = 0
        microphoneSilent = false
    }

    /// Level statistics for one finished recording, reported by the HUD.
    public mutating func recordingLevels(frames: Int, maxPeak: Float, durationMs: UInt64) {
        guard durationMs >= config.minSilentRecordingMs, frames >= config.minSilentFrames else { return }
        if maxPeak == 0 {
            silentStreak += 1
            if silentStreak >= config.silentRecordingsForMicrophoneHint { microphoneSilent = true }
        } else {
            silentStreak = 0
            microphoneSilent = false
        }
    }

    public mutating func tick(atMs now: UInt64) {
        if let c = noTextCheckMs, now >= c {
            noTextCheckMs = nil
            failure = .noText
        }
        if let p = pendingStartMs, now >= p + config.startTimeoutMs {
            pendingStartMs = nil
            if !state.isHot, state != .missing { failure = .didNotStart }
        }
        if let t = transcribingSinceMs, state.isTranscribing, now >= t + config.transcribeTimeoutMs {
            failure = .transcriptionStuck
        }
    }
}

/// Raw, read-only answers from the installed engine. nil means "could not tell".
public struct EngineProbeResult: Equatable, Sendable {
    public var binaryInstalled: Bool
    public var configuredEngine: String?
    /// Engine name → compiled into this binary.
    public var compiledEngines: [String: Bool]?
    public var configuredModel: String?
    /// Per-engine catalog: model name → installed.
    public var catalog: [String: [String: Bool]]?
    /// Entry names in Voxtype's model directory.
    public var localModelEntries: Set<String>?
    /// For a configured model given as an absolute path.
    public var configuredModelPathExists: Bool?
    public var postProcessIsVoicePop: Bool?

    public init(
        binaryInstalled: Bool,
        configuredEngine: String? = nil,
        compiledEngines: [String: Bool]? = nil,
        configuredModel: String? = nil,
        catalog: [String: [String: Bool]]? = nil,
        localModelEntries: Set<String>? = nil,
        configuredModelPathExists: Bool? = nil,
        postProcessIsVoicePop: Bool? = nil
    ) {
        self.binaryInstalled = binaryInstalled
        self.configuredEngine = configuredEngine
        self.compiledEngines = compiledEngines
        self.configuredModel = configuredModel
        self.catalog = catalog
        self.localModelEntries = localModelEntries
        self.configuredModelPathExists = configuredModelPathExists
        self.postProcessIsVoicePop = postProcessIsVoicePop
    }

    /// False only when the binary is missing or the configured engine is known not to be compiled in.
    public var engineUsable: Bool {
        guard binaryInstalled else { return false }
        guard let engine = configuredEngine, let compiled = compiledEngines?[engine] else { return true }
        return compiled
    }

    /// Whether the configured model is on disk: true/false only with evidence, nil when unknown.
    public var modelInstalled: Bool? {
        guard let model = configuredModel, !model.isEmpty else { return nil }
        if model.hasPrefix("/") { return configuredModelPathExists }
        let installed = Set((catalog ?? [:]).values.flatMap { $0.filter(\.value).map(\.key) })
        if installed.contains(model) { return true }
        if let local = localModelEntries, local.contains(model) || local.contains("ggml-\(model).bin") { return true }
        let engineCatalog = configuredEngine.flatMap { catalog?[$0] }
        if engineCatalog?[model] == false { return false }
        // Local variants such as "<catalog-name>-prepacked" are not listed in the catalog.
        if installed.contains(where: { model.hasPrefix($0 + "-") }) { return true }
        return nil
    }
}

/// Minimal read-only scan of Voxtype's TOML config for the values health checks need.
public enum VoxtypeConfigScan {
    /// `command` under `[output.post_process]`, or nil when absent or commented out.
    public static func postProcessCommand(in toml: String) -> String? {
        var section = ""
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard section == "output.post_process" else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "command" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\"") else { return nil }
            value.removeFirst()
            guard let end = value.firstIndex(of: "\"") else { return nil }
            return String(value[..<end])
        }
        return nil
    }
}
