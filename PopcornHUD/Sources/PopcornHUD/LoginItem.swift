import Foundation
import ServiceManagement

enum LoginItem {
    static let configuredKey = "loginItemConfigured"
    static let bundleID = "com.caleb.voicepop"

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isInstalledApp: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    static var isAvailable: Bool {
        isInstalledApp && Bundle.main.bundleIdentifier == bundleID
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // All SMAppService calls go through this one serial queue (N2-L6): register/unregister are
    // synchronous XPC round trips, and running two concurrently (e.g. a fast on/off/on) could let
    // completions arrive out of order and disagree with the toggle's actual final state.
    private static let queue = DispatchQueue(label: "com.caleb.voicepop.loginitem")
    // Bumped on every setEnabledAsync call (main thread only); a completion whose generation has
    // since been superseded by a newer call is dropped rather than applied out of order.
    private static var generation = 0

    static func registerIfNeeded() {
        guard isAvailable else { return }
        let defaults = UserDefaults.standard
        if isEnabled {
            defaults.set(true, forKey: configuredKey)
            return
        }
        guard !defaults.bool(forKey: configuredKey) else { return }
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: configuredKey)
        } catch {
            fputs("VoicePop login item register failed: \(error)\n", stderr)
        }
    }

    /// `SMAppService.status` is a synchronous XPC round trip - never call it on the main thread
    /// from a UI path that opens frequently (Settings General appearing/refreshing).
    static func isEnabledAsync(completion: @escaping (Bool) -> Void) {
        queue.async {
            let value = isEnabled
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// `SMAppService.register()`/`.unregister()` are synchronous XPC round trips too. Completion
    /// is delivered on main so the caller can apply an optimistic UI state and revert it on
    /// failure.
    ///
    /// Skips the call when already in the requested state - but "requested state" for *disabling*
    /// means `.notRegistered`, not merely "not `.enabled`" (N2-L6): `.requiresApproval` also
    /// reads as "not enabled", so comparing against `.enabled` for both directions meant turning
    /// the toggle off while macOS still had it pending approval never actually called
    /// `unregister()`, leaving it registered (and visible in Login Items) despite the toggle
    /// showing off. Also serialized on `queue` with a generation counter so a fast repeated
    /// toggle can't let an earlier call's completion land after a later one's and revert it.
    static func setEnabledAsync(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isAvailable else {
            completion(.failure(Failure(message: "Open at Login isn\u{2019}t available for this build.")))
            return
        }
        generation += 1
        let myGeneration = generation
        queue.async {
            do {
                let status = SMAppService.mainApp.status
                let alreadyAsRequested = enabled ? status == .enabled : status == .notRegistered
                if !alreadyAsRequested {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                }
                UserDefaults.standard.set(true, forKey: configuredKey)
                DispatchQueue.main.async {
                    guard generation == myGeneration else { return }
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == myGeneration else { return }
                    completion(.failure(error))
                }
            }
        }
    }
}
