import Foundation
import PopcornCore

final class VoxtypeWarmer {
    static let shared = VoxtypeWarmer()
    private let queue = DispatchQueue(label: "com.caleb.voicepop.warm", qos: .utility)
    private var lastAttempt: Date?

    /// Primes a cold Whisper engine after login. Never warms Parakeet - the
    /// daemon already preloads it - and never starts a second process if the
    /// daemon pid is alive (state file is written only after model load).
    func ensureWarm() {
        queue.async { [self] in
            if VoxtypeDaemon.engineIsParakeet() { return }
            if VoxtypeDaemon.isLive() { return }
            if let last = lastAttempt, Date().timeIntervalSince(last) < 60 { return }
            lastAttempt = Date()
            VoxtypeModel.warm()
        }
    }
}
