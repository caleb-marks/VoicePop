import Foundation
import Combine
import PopcornCore

extension Notification.Name {
    /// Posted after any successful `style.json` save (Settings or the menu bar), so every
    /// open `SettingsStore` can refresh instead of showing stale values or later clobbering a
    /// change made from the other surface. `object` is the poster (an `NSObject`-conforming
    /// identity is not required here - see `SettingsStore.refreshIfNeeded`), used only so a
    /// store that just wrote the change doesn't immediately reload its own value out from under
    /// in-flight edits.
    static let voicePopStylePrefsDidChange = Notification.Name("VoicePopStylePrefsDidChange")
}

/// Bridges `StylePrefsCache`/`StylePrefs` into SwiftUI for the Settings window. One instance per
/// window presentation; writes go through the same save path the menu bar uses
/// (`prefs.save()` + `StylePrefsCache.store`) so the menu and Settings never disagree, and both
/// sides post `.voicePopStylePrefsDidChange` so the other refreshes instead of going stale.
final class SettingsStore: ObservableObject {
    @Published var prefs: StylePrefs
    @Published var saveError: String?

    private var observer: NSObjectProtocol?

    init() {
        prefs = StylePrefsCache.current()
        observer = NotificationCenter.default.addObserver(
            forName: .voicePopStylePrefsDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? ObjectIdentifier) != ObjectIdentifier(self) else { return }
            self.prefs = StylePrefsCache.current()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Re-reads the cache. Call when the Settings window is (re)shown, in case the menu bar
    /// changed a style while the window was hidden (no notification would have fired then, since
    /// this instance didn't exist or wasn't observing yet in that exact window).
    func refreshFromCache() {
        prefs = StylePrefsCache.current()
    }

    /// Call after mutating `prefs` from a SwiftUI control.
    func save() {
        do {
            try prefs.save()
            StylePrefsCache.store(prefs)
            saveError = nil
            NotificationCenter.default.post(name: .voicePopStylePrefsDidChange, object: ObjectIdentifier(self))
        } catch {
            saveError = error.localizedDescription
        }
    }
}
