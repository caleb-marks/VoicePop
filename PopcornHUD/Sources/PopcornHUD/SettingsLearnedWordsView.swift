import AppKit
import SwiftUI
import PopcornCore

/// Learned Words tab (§3): a searchable, editable list of `Replacements` entries. Validates with
/// `Replacements.validate` (same rules `apply` uses at runtime), preserves edits and shows an
/// actionable error with Retry on save failure, and never silently overwrites a malformed file.
struct SettingsLearnedWordsView: View {
    @StateObject private var model: LearnedWordsViewModel
    @State private var search: String
    @State private var editingKey: String?
    @State private var editFrom = ""
    @State private var editTo = ""
    @State private var newFrom = ""
    @State private var newTo = ""
    @State private var addError: String?
    /// A List with no selection binding gives its rows no keyboard path at all - Tab skips
    /// straight from the search field to the list's scroll view, never reaching a row's Edit or
    /// Delete (flagged in review-2's harness key-view-loop walk). Selection restores standard
    /// List keyboard handling: arrow keys move the selection, and Return/Space activate a row's
    /// default action once VoiceOver/keyboard focus is on it.
    @State private var selection: String?
    /// Harness-only: skips the disk load so an injected fixture model's state isn't overwritten.
    private let skipAutoLoad: Bool

    init(fixtureModel: LearnedWordsViewModel? = nil, initialSearch: String = "") {
        _model = StateObject(wrappedValue: fixtureModel ?? LearnedWordsViewModel())
        _search = State(initialValue: initialSearch)
        skipAutoLoad = fixtureModel != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.loadState {
            case .malformed:
                malformedState
            case .ready:
                content
            }
        }
        // Without this, a VStack shorter than the window centers vertically instead of hugging
        // the top - most visible in the malformed state, which is just a few lines of text.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Reloading from disk is only safe once the in-memory state matches disk - i.e. no
        // pending save failure - otherwise a tab-switch-triggered reload would silently discard
        // edits the user is still trying to save (bug: reload must not race an open failure).
        .onAppear { if !skipAutoLoad, model.saveError == nil { model.load() } }
    }

    private var malformedState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("replacements.json can\u{2019}t be read", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("The learned-words file is malformed. It hasn\u{2019}t been changed or overwritten.")
                .foregroundStyle(.secondary)
            if model.hasPendingEdits {
                Text("Your unsaved edit will be applied after Move Aside and Start Fresh.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal in Finder") { model.revealInFinder() }
                Button("Move Aside and Start Fresh", role: .destructive) { model.quarantineAndStartFresh() }
            }
            if let error = model.quarantineError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var content: some View {
        VStack(spacing: 0) {
            // `.searchable` renders no field at all when hosted in a plain NSHostingController
            // without a NavigationStack (confirmed by rendering it offscreen in the UI snapshot
            // harness: the filtering worked, but no search box appeared anywhere) - macOS 13's
            // searchable requires navigation-view participation this window doesn't have. A
            // plain field works everywhere.
            List(selection: $selection) {
                // The search field lives inside the List so it gets the same grouped chrome as
                // the other tabs' Forms instead of a hand-drawn rounded box above the list.
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search learned words", text: $search)
                            .textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button {
                                search = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                        }
                    }
                }
                Section {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("From").font(.caption).foregroundStyle(.secondary)
                            TextField("what you often say", text: $newFrom)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("To").font(.caption).foregroundStyle(.secondary)
                            TextField("what it should become", text: $newTo)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button("Add") { add() }
                            .disabled(newFrom.isEmpty || newTo.isEmpty)
                    }
                    if let addError {
                        Text(addError).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    if model.entries.isEmpty {
                        emptyRow("No learned words yet",
                                 hint: "Corrections you save with Fix Last Dictation\u{2026} appear here.")
                    } else if filtered.isEmpty {
                        emptyRow("No matches for \u{201c}\(search)\u{201d}", hint: nil)
                    } else {
                        // Index, not \.from (a hand-edited file can have duplicate `from` keys,
                        // which would otherwise give ForEach duplicate identities).
                        ForEach(Array(filtered.enumerated()), id: \.offset) { _, entry in
                            row(entry)
                                .tag(entry.from)
                        }
                    }
                }
            }
            // Delete key deletes the selected row - a keyboard path to Delete that doesn't
            // depend on Tab reaching the row's own Delete button (review-2: List rows had no
            // keyboard path at all with no selection).
            .onDeleteCommand {
                guard let selection, let entry = model.entries.first(where: { $0.from == selection }) else { return }
                model.delete(entry)
                self.selection = nil
            }
            if let error = model.saveError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { model.retrySave() }
                }
                .padding(8)
            }
        }
    }

    /// Empty and no-results states: previously the list simply went blank with no explanation.
    private func emptyRow(_ title: String, hint: String?) -> some View {
        VStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }

    private var filtered: [Replacement] {
        guard !search.isEmpty else { return model.entries }
        return model.entries.filter {
            $0.from.localizedCaseInsensitiveContains(search) || $0.to.localizedCaseInsensitiveContains(search)
        }
    }

    @ViewBuilder
    private func row(_ entry: Replacement) -> some View {
        if editingKey == entry.from {
            HStack {
                TextField("From", text: $editFrom)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                TextField("To", text: $editTo)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { commitEdit(original: entry) }
                Button("Cancel") { editingKey = nil }
            }
        } else {
            HStack {
                Text(entry.from)
                Image(systemName: "arrow.right")
                Text(entry.to).fontWeight(.medium)
                Spacer()
                Text("\u{00d7}\(entry.count)").font(.caption).foregroundStyle(.tertiary)
                Button("Edit") {
                    editingKey = entry.from
                    editFrom = entry.from
                    editTo = entry.to
                }
                Button(role: .destructive) { model.delete(entry) } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete \(entry.from)")
            }
        }
    }

    private func add() {
        if let error = model.add(from: newFrom, to: newTo) {
            addError = error.localizedDescription
        } else {
            addError = nil
            newFrom = ""
            newTo = ""
        }
    }

    private func commitEdit(original: Replacement) {
        if let error = model.update(original: original, from: editFrom, to: editTo) {
            addError = error.localizedDescription
        } else {
            addError = nil
            editingKey = nil
        }
    }
}

@MainActor
final class LearnedWordsViewModel: ObservableObject {
    enum LoadState { case ready, malformed }

    @Published var entries: [Replacement] = []
    @Published var loadState: LoadState = .ready
    @Published var saveError: String?
    @Published var quarantineError: String?

    /// Fallback snapshot for `projectedEntries()` when the file is corrupt - the last known-good
    /// read, not authoritative.
    private var replacements = Replacements()
    /// Every edit not yet durably saved, oldest first, replayed in full on the current on-disk
    /// state at every save attempt (N2-M3). Cleared only once a save actually succeeds - so a
    /// failed edit is never silently dropped just because a *later* edit happens to save
    /// successfully, which is what happened when only the most recent mutation was kept.
    private var pendingMutations: [Replacements.Mutation] = []

    /// True while an edit made before the file most recently went missing/corrupt/changed
    /// underneath this tab hasn't been durably saved yet (R3-L1) - shown in the malformed state
    /// so the user knows an edit is waiting rather than assuming the list is simply empty.
    var hasPendingEdits: Bool { !pendingMutations.isEmpty }

    func load() {
        switch Replacements.inspect() {
        case .corrupt:
            loadState = .malformed
            return
        case .missing:
            replacements = Replacements()
        case .ready(let r):
            replacements = r
        }
        // Reflect (and, if possible, finally persist) any edit still queued from before the file
        // went missing/corrupt/changed underneath this tab (R3-L1) - otherwise `load()` showed
        // disk contents only, the queued edit became invisible everywhere (the list, and
        // `projectedEntries()`-based validation still counted it as a duplicate for "already
        // learned" purposes), and a later unrelated edit could silently save it without the user
        // ever seeing it land.
        entries = projectedEntries()
        if pendingMutations.isEmpty {
            loadState = .ready
        } else {
            flush()
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([VoicePopPaths.replacements])
    }

    /// Moves the malformed file aside so it is never silently overwritten. If the move itself
    /// fails (e.g. permissions), stay in the malformed state and surface why, rather than
    /// presenting an empty "ready" list that would then overwrite the still-broken file.
    func quarantineAndStartFresh() {
        do {
            try VoicePopPaths.quarantine(VoicePopPaths.replacements)
        } catch {
            quarantineError = "Couldn\u{2019}t move replacements.json aside. \(error.localizedDescription)"
            return
        }
        quarantineError = nil
        replacements = Replacements()
        entries = []
        loadState = .ready
        // Replay anything that was queued when the corruption was first hit, onto the now-fresh
        // (missing) file, instead of silently dropping it.
        flush()
    }

    @discardableResult
    func add(from: String, to: String) -> ReplacementValidationError? {
        // Manual entries are normalized the same way learned ones are (L-12): otherwise "Teh" and
        // a later correction-learned "teh" become case-duplicate entries that `apply` treats
        // differently (it matches keys case-insensitively but only stores one canonical `from`).
        // Trimmed before keying (N2-L3) - DiffLearner.key only strips punctuation, so " teh"
        // would otherwise be stored with its leading space and never match a learned "teh".
        let key = DiffLearner.key(from.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate against the file's current state plus anything already queued (N2-L3), not
        // the possibly-stale copy loaded when the tab appeared - so a word the correction window
        // just learned is also caught as a duplicate.
        if let error = Replacements.validate(from: key, to: trimmedTo, existing: projectedEntries()) {
            return error
        }
        let minCount = StylePrefsCache.current().learning.minCount
        let entry = Replacement(from: key, to: trimmedTo, count: max(1, minCount), lastTs: ISO8601DateFormatter().string(from: Date()))
        enqueue(.add(entry))
        return nil
    }

    /// `from` may change too (not just `to`); validated with `excluding` so the entry being
    /// edited never flags itself as a duplicate of its own prior key.
    @discardableResult
    func update(original: Replacement, from: String, to: String) -> ReplacementValidationError? {
        let key = DiffLearner.key(from.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = Replacements.validate(from: key, to: trimmedTo, existing: projectedEntries(), excluding: original.from) {
            return error
        }
        enqueue(.update(originalFrom: original.from, from: key, to: trimmedTo))
        return nil
    }

    func delete(_ entry: Replacement) {
        enqueue(.delete(from: entry.from))
    }

    /// Re-attempts every still-pending edit, replayed against the file's current state.
    func retrySave() {
        flush()
    }

    private func enqueue(_ mutation: Replacements.Mutation) {
        pendingMutations.append(mutation)
        entries = projectedEntries()
        flush()
    }

    /// The file's current on-disk state (or the last known-good snapshot, if it's corrupt) with
    /// every queued edit replayed on top - what the UI should show, and what validation should
    /// check new edits against.
    private func projectedEntries() -> [Replacement] {
        var r: Replacements
        switch Replacements.inspect() {
        case .ready(let x): r = x
        case .missing: r = Replacements()
        case .corrupt: r = replacements
        }
        for mutation in pendingMutations { r.apply(mutation) }
        return r.entries
    }

    /// Re-inspects the file and replays every pending mutation, in order, on top of whatever is
    /// actually on disk right now - never a stale copy this view model loaded earlier. Clears the
    /// queue only once the save actually succeeds (N2-M3); a save failure keeps every pending
    /// edit, not just the most recent one, so a later successful edit can't silently drop it.
    private func flush() {
        guard !pendingMutations.isEmpty else { return }
        var fresh: Replacements
        switch Replacements.inspect() {
        case .corrupt:
            // Switch straight to the malformed state instead of an error message telling the
            // user to "reopen Learned Words" - onAppear skips reloading while saveError is set,
            // so that instruction was a dead end (N2-L1). The queue and `entries` (already
            // reflecting the edit) are untouched, so Move Aside and Start Fresh can replay them.
            loadState = .malformed
            saveError = nil
            return
        case .missing:
            fresh = Replacements()
        case .ready(let r):
            fresh = r
        }
        let minCount = StylePrefsCache.current().learning.minCount
        for mutation in pendingMutations {
            fresh.apply(mutation)
            // An edited entry's count must not stay below minCount (N2-L3) - otherwise a manually
            // retargeted word that was originally learned once never applies once minCount > 1.
            if case .update(_, let from, _) = mutation, let idx = fresh.entries.firstIndex(where: { $0.from == from }) {
                fresh.entries[idx].count = max(fresh.entries[idx].count, minCount)
            }
        }
        do {
            try fresh.save()
            replacements = fresh
            entries = fresh.entries
            pendingMutations.removeAll()
            saveError = nil
            loadState = .ready
        } catch {
            saveError = "Couldn\u{2019}t save learned words. \(error.localizedDescription)"
        }
    }
}
