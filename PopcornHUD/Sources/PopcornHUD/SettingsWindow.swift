import AppKit
import PopcornCore

enum SettingsSection: String, CaseIterable {
    case general, appearance, dictation, learnedWords
}

/// One reusable native Settings window. Owned by the navigation/Settings workstream.
/// Main thread only.
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    /// Set once at startup by `AppDelegate`.
    var health: DictationHealthMonitor?

    /// Shows (or brings forward) the single Settings window on `section`.
    func show(_ section: SettingsSection = .general) {
        fputs("VoicePop: Settings requested (\(section.rawValue)) - not implemented yet\n", stderr)
    }
}
