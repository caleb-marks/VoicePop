import AppKit
import PopcornCore

private final class CorrectionPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

final class CorrectionWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static let shared = CorrectionWindowController()

    private var returnTo: NSRunningApplication?
    private var entry: HistoryEntry?
    private var textView: NSTextView?
    private var rawLabel: NSTextField?
    private var built = false

    func present() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != PopcornHUDMain.bundleID {
            returnTo = front
        }
        guard let entry = HistoryStore.last() else {
            let alert = NSAlert()
            alert.messageText = "Nothing to fix yet"
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            returnFocus()
            return
        }
        self.entry = entry
        if !built { buildWindow() }
        rawLabel?.stringValue = "What I heard: \(entry.raw)"
        textView?.string = entry.out
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    private func buildWindow() {
        let window = CorrectionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fix last text"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        window.contentView = content

        let label = NSTextField(labelWithString: "What I heard: ")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        rawLabel = label

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let tv = NSTextView()
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.allowsUndo = true
        tv.delegate = self
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        textView = tv

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        let save = NSButton(title: "Save & Learn", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        save.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(save)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])

        self.window = window
        built = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    @objc func save() {
        let corrected = (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let entry, corrected != entry.out, !corrected.isEmpty {
            CorrectionStore.append(CorrectionEntry(
                ts: ISO8601DateFormatter().string(from: Date()),
                app: entry.app,
                style: entry.style,
                typed: entry.out,
                corrected: corrected
            ))
            switch Replacements.inspect() {
            case .corrupt:
                Self.quarantine(VoicePopPaths.replacements)
                alert("Couldn’t save learned words", "replacements.json looks corrupt. It was moved to replacements.json.bad so it is not overwritten.")
                close()
                return
            case .missing:
                var r = Replacements()
                r.learn(typed: entry.rules, corrected: corrected, maxPhraseWords: StylePrefsCache.current().learning.maxPhraseWords)
                do {
                    try r.save()
                } catch {
                    alert("Could not save learned words", error.localizedDescription)
                }
            case .ready(var r):
                r.learn(typed: entry.rules, corrected: corrected, maxPhraseWords: StylePrefsCache.current().learning.maxPhraseWords)
                do {
                    try r.save()
                } catch {
                    alert("Could not save learned words", error.localizedDescription)
                }
            }
        }
        close()
    }

    private func alert(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.alertStyle = .warning
        a.runModal()
    }

    private static func quarantine(_ url: URL) {
        let bad = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
    }

    @objc func cancel() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        returnFocus()
    }

    private func returnFocus() {
        if let app = returnTo, !app.isTerminated {
            app.activate()
        } else {
            NSApp.hide(nil)
        }
    }
}
