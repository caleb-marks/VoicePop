import AppKit
import PopcornCore

private final class CorrectionPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// The "Fix last text" editor (§4 of the polish spec). Save & Learn only teaches future
/// dictation - it never touches text already inserted elsewhere - so the window explains that,
/// offers a literal "Copy Corrected Text" action, and keeps the window and its contents open on
/// a save failure with an inline, actionable error and Retry.
final class CorrectionWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static let shared = CorrectionWindowController()

    private var returnTo: NSRunningApplication?
    private var entry: HistoryEntry?
    private var textView: NSTextView?
    private var rawLabel: NSTextField?
    private var explainLabel: NSTextField?
    private var errorLabel: NSTextField?
    private var retryButton: NSButton?
    private var saveButton: NSButton?
    private var built = false
    /// One saver per presented entry: it remembers which correction record it already appended,
    /// so pressing Save again after a failure (Retry) never writes a duplicate.
    private var saver: CorrectionSaver?

    /// Harness-only (`VOICEPOP_UI_SNAPSHOT`): builds and populates the window from a fixture
    /// entry without touching `HistoryStore`, optionally showing the inline error+Retry state.
    func presentFixture(entry: HistoryEntry, correctedText: String, errorMessage: String? = nil) {
        self.entry = entry
        self.saver = CorrectionSaver()
        if !built { buildWindow() }
        rawLabel?.stringValue = "What I heard: \(entry.raw)"
        textView?.string = correctedText
        setError(errorMessage)
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// Reads the last dictation off the main thread (via `LastHistoryEntryCache`, usually already
    /// warm) and presents once it returns - `history.jsonl` must never be tail-read synchronously
    /// on the thread handling a menu click or global shortcut.
    func present() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != PopcornHUDMain.bundleID {
            returnTo = front
        }
        LastHistoryEntryCache.currentAsync { [weak self] entry in
            self?.presentResolved(entry)
        }
    }

    private func presentResolved(_ entry: HistoryEntry?) {
        guard let entry else {
            let alert = NSAlert()
            alert.messageText = "Nothing to fix yet"
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            returnFocus()
            return
        }
        self.entry = entry
        self.saver = CorrectionSaver()
        if !built { buildWindow() }
        rawLabel?.stringValue = "What I heard: \(entry.raw)"
        textView?.string = entry.out
        setError(nil)
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    private func buildWindow() {
        let window = CorrectionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fix last text"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 380))
        window.contentView = content

        let label = NSTextField(labelWithString: "What I heard: ")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        rawLabel = label

        let explain = NSTextField(wrappingLabelWithString:
            "\u{201c}Save & Learn\u{201d} teaches VoicePop this correction for future dictation. It does not change the text you already typed elsewhere.")
        explain.font = NSFont.systemFont(ofSize: 11)
        explain.textColor = .tertiaryLabelColor
        explain.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(explain)
        explainLabel = explain

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
        tv.setAccessibilityLabel("Corrected text")
        scroll.documentView = tv
        textView = tv

        let error = NSTextField(wrappingLabelWithString: "")
        error.font = NSFont.systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.translatesAutoresizingMaskIntoConstraints = false
        error.isHidden = true
        content.addSubview(error)
        errorLabel = error

        let retry = NSButton(title: "Retry", target: self, action: #selector(save))
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.isHidden = true
        content.addSubview(retry)
        retryButton = retry

        let copy = NSButton(title: "Copy Corrected Text", target: self, action: #selector(copyCorrected))
        copy.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(copy)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        let save = NSButton(title: "Save & Learn", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        save.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(save)
        saveButton = save

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            explain.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            explain.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            explain.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: explain.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: error.topAnchor, constant: -8),

            error.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            error.trailingAnchor.constraint(lessThanOrEqualTo: retry.leadingAnchor, constant: -8),
            error.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -10),

            retry.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            retry.centerYAnchor.constraint(equalTo: error.centerYAnchor),

            copy.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

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

    /// Copies exactly what is in the text view - not trimmed - per spec: "Copy returns exactly
    /// the edited text."
    @objc func copyCorrected() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView?.string ?? "", forType: .string)
    }

    @objc func save() {
        guard let entry, let saver else { close(); return }
        let corrected = textView?.string ?? ""
        do {
            _ = try saver.save(
                entry: entry,
                correctedText: corrected,
                maxPhraseWords: StylePrefsCache.current().learning.maxPhraseWords
            )
            close()
        } catch {
            // Keep the window and the user's edits open; show an actionable error with Retry
            // instead of silently discarding the correction (§4 requirement).
            setError((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func setError(_ message: String?) {
        errorLabel?.stringValue = message ?? ""
        errorLabel?.isHidden = message == nil
        retryButton?.isHidden = message == nil
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
