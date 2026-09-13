import AppKit
import Foundation
import PopcornCore

enum VoxtypeDaemon {
    static func isLive() -> Bool {
        DaemonProcess.isLive(pidPath: Paths.pid)
    }

    static func engineIsParakeet() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voxtype/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { continue }
            if t.hasPrefix("engine"), t.contains("\"parakeet\"") { return true }
        }
        return false
    }
}

/// Daemon state for the app. Event-driven (see `DaemonStateObserver`); listeners run on main.
final class StateWatcher {
    private let observer: DaemonStateObserver
    private var wakeObserver: NSObjectProtocol?

    /// Main thread: the most recent state delivered to listeners.
    private(set) var state: DaemonState = .missing

    init(configuration: DaemonStateObserver.Configuration = .init()) {
        observer = DaemonStateObserver(configuration: configuration)
        observer.addListener { [weak self] next in
            self?.state = next
            Timing.event("state.delivered", ["state": next.timingName])
        }
    }

    /// `block` runs on main: once with the current state, then on every change.
    func addListener(_ block: @escaping (DaemonState) -> Void) {
        observer.addListener(block)
    }

    func start() {
        observer.start()
        // Vnode and process sources survive sleep, but one authoritative re-read after wake is cheap.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.observer.reconcileNow()
        }
    }

    func stop() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        observer.stop()
    }
}
