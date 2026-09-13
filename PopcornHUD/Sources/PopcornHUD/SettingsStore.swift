import Foundation
import Combine
import PopcornCore

/// Bridges `StylePrefsCache`/`StylePrefs` into SwiftUI for the Settings window. One instance per
/// window presentation; writes go through `StatusItemController`'s same save path
/// (`prefs.save()` + `StylePrefsCache.store`) so the menu and Settings never disagree.
final class SettingsStore: ObservableObject {
    @Published var prefs: StylePrefs
    @Published var saveError: String?

    init() {
        prefs = StylePrefsCache.current()
    }

    /// Call after mutating `prefs` from a SwiftUI control.
    func save() {
        do {
            try prefs.save()
            StylePrefsCache.store(prefs)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
