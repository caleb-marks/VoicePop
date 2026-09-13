import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable {
    case general, appearance, dictation, learnedWords
}

/// One reusable native Settings window (§3 of the polish spec). AppKit `NSTabViewController`
/// with a toolbar tab style, hosting SwiftUI `Form`s - deliberately not a SwiftUI `Settings`
/// scene, since this app has an AppKit `NSApplication` lifecycle (macOS 13 target, no
/// `@main App`). Main thread only.
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    /// Set once at startup by `AppDelegate`.
    var health: DictationHealthMonitor?

    private var windowController: NSWindowController?
    private var tabViewController: NSTabViewController?
    private let store = SettingsStore()

    private static let sectionOrder: [SettingsSection] = [.general, .appearance, .dictation, .learnedWords]
    private static func title(for section: SettingsSection) -> String {
        switch section {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .dictation: return "Dictation"
        case .learnedWords: return "Learned Words"
        }
    }
    private static func symbol(for section: SettingsSection) -> String {
        switch section {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .dictation: return "waveform"
        case .learnedWords: return "text.book.closed"
        }
    }

    /// Shows (or brings forward) the single Settings window on `section`.
    func show(_ section: SettingsSection = .general) {
        if windowController == nil {
            buildWindow()
        }
        // Pick up anything the menu bar changed (e.g. Writing Style) while the window was hidden.
        store.refreshFromCache()
        // Retried on every show() (cheap - a bool check once attached): if the window was built
        // via ⌘, before AppDelegate set `health` during first-run setup, this is how General and
        // Appearance ever pick it up (L-1). attachHealthIfNeeded no-ops once already attached, so
        // this can never register more than one listener for the window's lifetime (M-7).
        store.attachHealthIfNeeded(health)
        select(section)
        NSApp.activate(ignoringOtherApps: true)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for section in Self.sectionOrder {
            let hosting: NSViewController
            switch section {
            case .general:
                hosting = NSHostingController(rootView: SettingsGeneralView(store: store))
            case .appearance:
                hosting = NSHostingController(rootView: SettingsAppearanceView(store: store))
            case .dictation:
                hosting = NSHostingController(rootView: SettingsDictationView(store: store))
            case .learnedWords:
                hosting = NSHostingController(rootView: SettingsLearnedWordsView())
            }
            hosting.title = Self.title(for: section)
            let item = NSTabViewItem(viewController: hosting)
            item.label = Self.title(for: section)
            item.image = NSImage(systemSymbolName: Self.symbol(for: section), accessibilityDescription: Self.title(for: section))
            tabs.addTabViewItem(item)
        }
        tabViewController = tabs

        let window = NSWindow(contentViewController: tabs)
        window.title = "VoicePop Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setFrameAutosaveName("VoicePopSettings")
        // 620 tall: the Dictation tab (6 models + writing style + polishing toggle) and General
        // (shortcut guidance + live recovery actions) both clip important content at 460 - a
        // download's progress row in particular must not require scrolling to notice.
        window.setContentSize(NSSize(width: 520, height: 620))
        window.minSize = NSSize(width: 480, height: 420)
        window.center()
        window.isReleasedWhenClosed = false
        windowController = NSWindowController(window: window)
    }

    private func select(_ section: SettingsSection) {
        guard let tabs = tabViewController,
              let index = Self.sectionOrder.firstIndex(of: section) else { return }
        tabs.selectedTabViewItemIndex = index
    }
}
