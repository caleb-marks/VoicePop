import Foundation
import ServiceManagement

enum LoginItem {
    static let configuredKey = "loginItemConfigured"
    static let bundleID = "com.caleb.voicepop"

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

    static func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(true, forKey: configuredKey)
        } catch {
            fputs("VoicePop login item update failed: \(error)\n", stderr)
        }
    }
}
