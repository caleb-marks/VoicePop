import AppKit
import PopcornCore

extension Notification.Name {
    static let voicePopMascotDidChange = Notification.Name("VoicePopMascotDidChange")
}

@main
enum PopcornHUDMain {
    static let bundleID = "com.caleb.voicepop"
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: HUDController?
    private var statusItem: StatusItemController?
    private let stateWatcher = StateWatcher()
    private var previousApp: NSRunningApplication?

    func applicationWillFinishLaunching(_ notification: Notification) {
        installMainMenu()
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != PopcornHUDMain.bundleID {
            previousApp = front
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SetupAssistant.runIfNeeded { [self] in startServices() }
    }

    private func startServices() {
        LoginItem.registerIfNeeded()
        let prefs = StylePrefsCache.current()
        if OllamaWarmer.formalInEffect(prefs) { OllamaWarmer.shared.ensureWarm(prefs.llm) }
        NSApp.applicationIconImage = StatusItemIcon.dockImage()

        stateWatcher.start()

        let status = StatusItemController()
        status.start(watcher: stateWatcher)
        statusItem = status

        controller = HUDController()
        controller?.start(watcher: stateWatcher)
        fputs("VoicePop menu bar item ready\n", stderr)
        VoxtypeWarmer.shared.ensureWarm()
        yieldFocus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if statusItem?.revealMenu() != true {
            fputs("VoicePop reopen: status item not clickable (overflow or missing)\n", stderr)
        }
        yieldFocus()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItem?.stop()
        statusItem = nil
        controller = nil
        stateWatcher.stop()
    }

    private func yieldFocus() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let prev = previousApp, prev.processIdentifier != selfPID, !prev.isTerminated {
            prev.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    private func installMainMenu() {
        let menubar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit VoicePop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menubar.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menubar.addItem(editItem)

        NSApp.mainMenu = menubar
    }
}
