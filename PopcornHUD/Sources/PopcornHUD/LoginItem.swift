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
        DispatchQueue.global(qos: .utility).async {
            let value = isEnabled
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// `SMAppService.register()`/`.unregister()` are synchronous XPC round trips too. Completion
    /// is delivered on main so the caller can apply an optimistic UI state and revert it on
    /// failure. Skips the call entirely when the service is already in the requested state
    /// (checked off-main, right before acting), so a caller that re-applies a known-good value -
    /// e.g. a load that happens to match what's already registered - never pointlessly calls
    /// `register()` on an already-registered service (which the SDK docs say returns
    /// `kSMErrorAlreadyRegistered`).
    static func setEnabledAsync(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isAvailable else {
            completion(.failure(Failure(message: "Open at Login isn\u{2019}t available for this build.")))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                if isEnabled != enabled {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                }
                UserDefaults.standard.set(true, forKey: configuredKey)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
