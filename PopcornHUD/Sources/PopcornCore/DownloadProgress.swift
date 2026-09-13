import Foundation

/// One `voxtype-bin setup --download --progress-format json` event, parsed. Pure and
/// side-effect-free so the Settings Dictation tab's progress/failure UI can be tested against
/// fixture lines without ever spawning the real process or touching the network.
public enum ModelDownloadEvent: Equatable, Sendable {
    case progress(fraction: Double, bytesGB: Double, totalGB: Double)
    case failure(String)
}

public enum ModelDownloadProgress {
    /// Returns nil for lines that are not a recognized progress/error event (e.g. blank lines,
    /// other log output interleaved on the same stream).
    public static func parse(line: String) -> ModelDownloadEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String
        else { return nil }
        if event == "error" {
            let message = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "Model download failed."
            return .failure(message)
        }
        guard event == "progress", let pct = obj["pct"] as? Double else { return nil }
        let bytes = (obj["bytes"] as? Double ?? 0) / 1_073_741_824
        let total = (obj["total"] as? Double ?? 0) / 1_073_741_824
        return .progress(fraction: pct / 100, bytesGB: bytes, totalGB: total)
    }
}
