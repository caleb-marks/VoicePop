import Foundation
import PopcornCore

/// Publishes `DictationStatus` (daemon state + engine facts) to main-queue listeners.
/// Owned by the responsiveness/reliability workstream. The menu, Settings, onboarding, and HUD
/// read status only through this type; they never probe the engine on the main thread.
final class DictationHealthMonitor {
    private let watcher: StateWatcher
    private var listeners: [(DictationStatus) -> Void] = []
    private var facts = EngineFacts()
    private(set) var status = DictationStatus(daemon: .missing, facts: EngineFacts())

    init(watcher: StateWatcher) {
        self.watcher = watcher
    }

    /// Main thread. Calls `block` immediately with the current status, then on every change.
    func addListener(_ block: @escaping (DictationStatus) -> Void) {
        listeners.append(block)
        block(status)
    }

    /// Main thread.
    func start() {
        watcher.addListener { [weak self] state in
            self?.publish(daemon: state)
        }
        refresh()
    }

    /// Re-probe engine/model facts off the main thread (e.g. after setup or a model switch).
    func refresh() {
        let installed = EngineControl.isEngineInstalled
        update { $0.engineInstalled = installed }
    }

    /// Model downloads started from Settings or onboarding report progress here. nil clears.
    func noteModelDownload(_ download: EngineFacts.Download?) {
        update { $0.download = download }
    }

    /// The HUD reports whether microphone levels are arriving while recording.
    func noteAudioLevels(available: Bool) {
        update { $0.audioLevelsUnavailable = !available }
    }

    /// Main thread.
    func update(_ change: (inout EngineFacts) -> Void) {
        var next = facts
        change(&next)
        guard next != facts else { return }
        facts = next
        publish(daemon: status.daemon)
    }

    private func publish(daemon: DaemonState) {
        let next = DictationStatus(daemon: daemon, facts: facts)
        guard next != status else { return }
        status = next
        for cb in listeners { cb(next) }
    }
}
