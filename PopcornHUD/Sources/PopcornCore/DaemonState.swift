import Foundation

public enum DaemonState: Equatable, Sendable {
    case missing
    case idle
    case recording
    case streaming
    case transcribing
    case other(String)

    public var isHot: Bool {
        switch self {
        case .recording, .streaming: return true
        default: return false
        }
    }

    public var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }

    public var statusLabel: String {
        switch self {
        case .recording: return "Recording"
        case .streaming: return "Streaming"
        case .transcribing: return "Transcribing…"
        case .idle: return ""
        case .missing: return ""
        case .other(let s): return s
        }
    }

    public static func parse(_ raw: String?) -> DaemonState {
        guard let raw else { return .missing }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": return .missing
        case "idle": return .idle
        case "recording": return .recording
        case "streaming": return .streaming
        case "transcribing": return .transcribing
        case let s: return .other(s)
        }
    }
}

public enum HUDPresentation: Equatable, Sendable {
    case hidden
    case recording
    case transcribing
}

public enum VoicePopSignal {
    /// Posted by voxtype-clean immediately before it writes stdout, i.e. the moment
    /// transcription + cleanup is done and before the daemon starts typing.
    public static let transcriptReady = "com.caleb.voicepop.transcript-ready"
}
