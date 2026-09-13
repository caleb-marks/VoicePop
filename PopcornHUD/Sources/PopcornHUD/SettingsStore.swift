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
///
/// Also the single place `DictationHealthMonitor` is observed for the whole Settings window
/// (`attachHealthIfNeeded`), so General and Appearance read `status` here instead of each adding
/// their own permanent listener on every `onAppear` (M-7: the monitor has no listener-removal
/// yet, so unbounded per-tab registrations would otherwise accumulate over a long session).
final class SettingsStore: ObservableObject {
    @Published var prefs: StylePrefs
    @Published var saveError: String?
    @Published var status = DictationStatus(daemon: .missing, facts: EngineFacts())

    private var observer: NSObjectProtocol?
    private weak var attachedHealth: DictationHealthMonitor?
    private var healthToken: DictationHealthMonitor.ListenerToken?

    init() {
        prefs = StylePrefsCache.current()
        observer = NotificationCenter.default.addObserver(
            forName: .voicePopStylePrefsDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? ObjectIdentifier) != ObjectIdentifier(self) else { return }
            self.prefs = StylePrefsCache.current()
            // The cache just changed from elsewhere (the menu, or another Settings window) - a
            // pending error about a now-superseded attempted value would be stale and confusing
            // next to the freshly reloaded one (R3-L2).
            self.saveError = nil
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let attachedHealth, let healthToken { attachedHealth.removeListener(healthToken) }
    }

    /// Re-reads the cache. Call when the Settings window is (re)shown, in case the menu bar
    /// changed a style while the window was hidden (no notification would have fired then, since
    /// this instance didn't exist or wasn't observing yet in that exact window). Also drops any
    /// stale `saveError` (R3-L2): showing an old error next to a freshly reloaded value - possibly
    /// the very value that failed to save last time, now silently "current" again - was worse
    /// than just clearing it.
    func refreshFromCache() {
        prefs = StylePrefsCache.current()
        saveError = nil
    }

    /// One-time registration for the store's (and so the window's) lifetime. Safe to call
    /// repeatedly - a no-op once attached, and a no-op while `health` is still nil (so a window
    /// built before `AppDelegate` sets `health` picks it up on a later call instead of never).
    func attachHealthIfNeeded(_ health: DictationHealthMonitor?) {
        guard healthToken == nil, let health else { return }
        attachedHealth = health
        healthToken = health.addListener { [weak self] status in
            self?.status = status
        }
    }

    /// Call after mutating `prefs` from a SwiftUI control. On failure, keeps the attempted value
    /// in `prefs` (so the control the user just touched doesn't silently snap back with no
    /// explanation) and sets `saveError`, which `SettingsAppearanceView`/`SettingsDictationView`
    /// show inline with a Retry button that just calls `save()` again (M-8 - a bare rollback with
    /// no visible error, tried in an earlier pass, left the failure invisible: the control
    /// reverted, but the menu, cache, and `voxtype-clean` still silently kept the old value too,
    /// which is what a rollback alone amounts to - so review-2 correctly called that incomplete).
    func save() {
        do {
            try prefs.save()
            StylePrefsCache.store(prefs)
            saveError = nil
            NotificationCenter.default.post(name: .voicePopStylePrefsDidChange, object: ObjectIdentifier(self))
        } catch {
            saveError = "Couldn’t save this setting. \(error.localizedDescription) Your change is kept here; choose Retry to save it."
        }
    }
}
