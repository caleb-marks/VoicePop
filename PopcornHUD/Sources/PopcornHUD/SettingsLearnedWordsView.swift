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
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 4)

            List {
                Section {
                    HStack {
                        TextField("From (what you often say)", text: $newFrom)
                        TextField("To (what it should become)", text: $newTo)
                        Button("Add") { add() }
                            .disabled(newFrom.isEmpty || newTo.isEmpty)
                    }
                    if let addError {
                        Text(addError).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(filtered, id: \.from) { entry in
                        row(entry)
                    }
                }
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
                Image(systemName: "arrow.right")
                TextField("To", text: $editTo)
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

    private var replacements = Replacements()

    func load() {
        switch Replacements.inspect() {
        case .missing:
            replacements = Replacements()
            entries = []
            loadState = .ready
        case .ready(let r):
            replacements = r
            entries = r.entries
            loadState = .ready
        case .corrupt:
            loadState = .malformed
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([VoicePopPaths.replacements])
    }

    /// Moves the malformed file aside so it is never silently overwritten. If the move itself
    /// fails (e.g. permissions), stay in the malformed state and surface why, rather than
    /// presenting an empty "ready" list that would then overwrite the still-broken file.
    func quarantineAndStartFresh() {
        let bad = VoicePopPaths.replacements.appendingPathExtension("bad")
        do {
            if FileManager.default.fileExists(atPath: bad.path) {
                try FileManager.default.removeItem(at: bad)
            }
            try FileManager.default.moveItem(at: VoicePopPaths.replacements, to: bad)
            try? VoicePopPaths.secureFile(bad)
        } catch {
            quarantineError = "Couldn\u{2019}t move replacements.json aside. \(error.localizedDescription)"
            return
        }
        quarantineError = nil
        replacements = Replacements()
        entries = []
        loadState = .ready
    }

    @discardableResult
    func add(from: String, to: String) -> ReplacementValidationError? {
        if let error = Replacements.validate(from: from, to: to, existing: replacements.entries) {
            return error
        }
        let entry = Replacement(
            from: from.trimmingCharacters(in: .whitespacesAndNewlines),
            to: to.trimmingCharacters(in: .whitespacesAndNewlines),
            count: 1,
            lastTs: ISO8601DateFormatter().string(from: Date())
        )
        replacements.entries.append(entry)
        entries = replacements.entries
        persist()
        return nil
    }

    /// `from` may change too (not just `to`); validated with `excluding` so the entry being
    /// edited never flags itself as a duplicate of its own prior key.
    @discardableResult
    func update(original: Replacement, from: String, to: String) -> ReplacementValidationError? {
        if let error = Replacements.validate(from: from, to: to, existing: replacements.entries, excluding: original.from) {
            return error
        }
        guard let idx = replacements.entries.firstIndex(where: { $0.from == original.from }) else { return nil }
        replacements.entries[idx].from = from.trimmingCharacters(in: .whitespacesAndNewlines)
        replacements.entries[idx].to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = replacements.entries
        persist()
        return nil
    }

    func delete(_ entry: Replacement) {
        replacements.entries.removeAll { $0.from == entry.from }
        entries = replacements.entries
        persist()
    }

    /// Re-attempts writing whatever the current in-memory state already is. Must not re-run
    /// add/update/delete: those already mutated `replacements`, so re-running them would
    /// re-validate against the post-mutation state and (for `add`) fail as a duplicate of the
    /// entry it just added, silently swallowing the retry.
    func retrySave() {
        persist()
    }

    /// Saves, and on failure keeps the in-memory edit (already applied to `entries` by the
    /// caller) so the UI never discards what the user typed - only Retry re-attempts the write.
    private func persist() {
        do {
            try replacements.save()
            saveError = nil
        } catch {
            saveError = "Couldn\u{2019}t save learned words. \(error.localizedDescription)"
        }
    }
}
