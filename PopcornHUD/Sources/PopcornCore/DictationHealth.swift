import Foundation

/// Facts about the local engine that decide whether FN dictation can work right now.
/// Gathered off the main thread by `DictationHealthMonitor`; unknown values stay optimistic
/// (`nil`/`false`) so a slow probe never blocks or falsely alarms.
public struct EngineFacts: Equatable, Sendable {
    public struct Download: Equatable, Sendable {
        public var model: String
        /// 0...1 when the engine reports progress; nil while indeterminate.
        public var fraction: Double?
        public init(model: String, fraction: Double?) {
            self.model = model
            self.fraction = fraction
        }
    }

    public var engineInstalled: Bool
    /// nil until the first probe finishes.
    public var modelInstalled: Bool?
    public var modelTitle: String?
    public var download: Download?
    /// True only with evidence (verified or functional check). Never inferred from silence alone.
    public var permissionsNeeded: Bool
    /// Which permission the evidence points at, when known.
    public var permissionHint: PermissionHint?
    /// Why the engine is unusable when it is installed but cannot run the configured engine.
    public var engineProblem: String?
    /// Set while recording when no microphone-level packets arrive.
    public var audioLevelsUnavailable: Bool
    /// Last distinguishable transcription/insertion failure, cleared by the next success.
    public var lastFailure: String?

    public init(
        engineInstalled: Bool = true,
        modelInstalled: Bool? = nil,
        modelTitle: String? = nil,
        download: Download? = nil,
        permissionsNeeded: Bool = false,
        audioLevelsUnavailable: Bool = false,
        lastFailure: String? = nil
    ) {
        self.engineInstalled = engineInstalled
        self.modelInstalled = modelInstalled
        self.modelTitle = modelTitle
        self.download = download
        self.permissionsNeeded = permissionsNeeded
        self.audioLevelsUnavailable = audioLevelsUnavailable
        self.lastFailure = lastFailure
    }
}

/// Permission a functional check points at. Permissions belong to Voxtype.app, not VoicePop.
public enum PermissionHint: String, Equatable, Sendable {
    /// Recent recordings delivered frames whose peak was exactly zero.
    case microphone
}

/// The single most important thing standing between the user and dictation.
public enum DictationIssue: Equatable, Sendable {
    case engineNotInstalled
    case modelDownloading(fraction: Double?)
    case modelMissing
    case engineNotRunning
    case permissionsNeeded
    case lastDictationFailed(String)
    case audioLevelsUnavailable
}

public enum RecoveryAction: String, Equatable, Sendable, CaseIterable {
    case openSetup
    case restartEngine
    case retryDownload
    case openPrivacySettings
    case openSettings
    case copyLastText
}

/// Derived, UI-ready dictation status. Pure: equal inputs give equal output, so the menu,
/// Settings, onboarding, and HUD can all render the same truth.
public struct DictationStatus: Equatable, Sendable {
    public var daemon: DaemonState
    public var facts: EngineFacts

    public init(daemon: DaemonState, facts: EngineFacts) {
        self.daemon = daemon
        self.facts = facts
    }

    public var issue: DictationIssue? {
        if !facts.engineInstalled { return .engineNotInstalled }
        if let d = facts.download { return .modelDownloading(fraction: d.fraction) }
        if facts.modelInstalled == false { return .modelMissing }
        if daemon == .missing { return .engineNotRunning }
        if facts.permissionsNeeded { return .permissionsNeeded }
        if daemon.isHot, facts.audioLevelsUnavailable { return .audioLevelsUnavailable }
        if !daemon.isHot, !daemon.isTranscribing, let failure = facts.lastFailure { return .lastDictationFailed(failure) }
        return nil
    }

    /// True when holding FN is expected to start a recording.
    public var canDictate: Bool {
        switch issue {
        case nil, .audioLevelsUnavailable, .lastDictationFailed: return daemon != .missing
        default: return false
        }
    }

    /// First line of the menu, e.g. "Ready · Hold FN to dictate".
    public var headline: String {
        switch daemon {
        case .recording, .streaming: return "Recording…"
        case .transcribing: return "Transcribing…"
        default: break
        }
        switch issue {
        case .engineNotInstalled: return "Speech engine not installed"
        case .modelDownloading(let f):
            if let f { return "Downloading speech model… \(Int((f * 100).rounded()))%" }
            return "Downloading speech model…"
        case .modelMissing: return "Speech model not installed"
        case .engineNotRunning: return "Dictation isn’t running"
        case .permissionsNeeded:
            return facts.permissionHint == .microphone ? "Voxtype can’t hear the microphone" : "Voxtype needs permission"
        case .lastDictationFailed(let message):
            return DictationFailure(rawValue: message) != nil ? message : "Last dictation didn’t finish"
        case .audioLevelsUnavailable, nil:
            if case .other(let s) = daemon { return s.capitalized }
            return "Ready · Hold FN to dictate"
        }
    }

    /// Optional second line explaining the headline and what to do. nil when there is nothing to add.
    public var detail: String? {
        switch issue {
        case .engineNotInstalled:
            return facts.engineProblem ?? "Set up Voxtype to dictate."
        case .modelDownloading:
            return facts.download.map { "Dictation works again when “\($0.model)” finishes downloading." }
        case .modelMissing:
            return facts.modelTitle.map { "Download “\($0)” or choose another model." } ?? "Download a speech model to dictate."
        case .engineNotRunning:
            return "Restart dictation to try again."
        case .permissionsNeeded:
            if facts.permissionHint == .microphone {
                return "Recent recordings were completely silent. In Privacy & Security → Microphone, allow Voxtype."
            }
            return "Grant the permissions Voxtype asks for in Privacy & Security."
        case .lastDictationFailed(let message):
            switch DictationFailure(rawValue: message) {
            case .noText: return "VoicePop didn’t receive text from it. Try again, speaking a little longer."
            case .didNotStart, .stoppedUnexpectedly: return "Try again. If it keeps happening, restart dictation."
            case .transcriptionStuck: return "Wait a moment, or restart dictation."
            case nil: return message
            }
        case .audioLevelsUnavailable:
            return "Recording continues, but VoicePop can’t show your voice level."
        case nil:
            return nil
        }
    }

    public var actions: [RecoveryAction] {
        switch issue {
        case .engineNotInstalled, .modelMissing: return [.openSetup]
        case .modelDownloading: return [.openSettings]
        case .engineNotRunning: return [.restartEngine, .openSetup]
        case .permissionsNeeded: return [.openPrivacySettings, .openSetup]
        case .lastDictationFailed(let message):
            // Known failures produced no new text, so copying would copy an older dictation.
            return DictationFailure(rawValue: message) == nil ? [.copyLastText, .restartEngine] : [.restartEngine]
        case .audioLevelsUnavailable: return [.restartEngine]
        case nil: return []
        }
    }
}
