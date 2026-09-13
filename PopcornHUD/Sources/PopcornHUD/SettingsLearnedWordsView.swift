import AppKit
import SwiftUI
import PopcornCore

/// Learned Words tab (§3): a searchable, editable list of `Replacements` entries. Validates with
/// `Replacements.validate` (same rules `apply` uses at runtime), preserves edits and shows an
/// actionable error with Retry on save failure, and never silently overwrites a malformed file.
struct SettingsLearnedWordsView: View {
    @StateObject private var model = LearnedWordsViewModel()
    @State private var search = ""
    @State private var editing: Replacement?
    @State private var newFrom = ""
    @State private var newTo = ""
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.loadState {
            case .malformed:
                malformedState
            case .ready:
                content
            }
        }
        .onAppear { model.load() }
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
        }
        .padding()
    }

    private var content: some View {
        VStack(spacing: 0) {
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
        .searchable(text: $search, prompt: "Search learned words")
    }

    private var filtered: [Replacement] {
        guard !search.isEmpty else { return model.entries }
        return model.entries.filter {
            $0.from.localizedCaseInsensitiveContains(search) || $0.to.localizedCaseInsensitiveContains(search)
        }
    }

    @ViewBuilder
    private func row(_ entry: Replacement) -> some View {
        if editing?.from == entry.from {
            let toBinding = Binding(
                get: { editing?.to ?? entry.to },
                set: { editing?.to = $0 }
            )
            HStack {
                Text(entry.from).foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                TextField("To", text: toBinding)
                Button("Save") { commitEdit(original: entry) }
                Button("Cancel") { editing = nil }
            }
        } else {
            HStack {
                Text(entry.from)
                Image(systemName: "arrow.right")
                Text(entry.to).fontWeight(.medium)
                Spacer()
                Text("\u{00d7}\(entry.count)").font(.caption).foregroundStyle(.tertiary)
                Button("Edit") { editing = entry }
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
        guard let editing else { return }
        if let error = model.update(original: original, to: editing.to) {
            addError = error.localizedDescription
        } else {
            self.editing = nil
        }
    }
}

@MainActor
final class LearnedWordsViewModel: ObservableObject {
    enum LoadState { case ready, malformed }

    @Published var entries: [Replacement] = []
    @Published var loadState: LoadState = .ready
    @Published var saveError: String?

    private var replacements = Replacements()
    private var lastAction: (() -> Void)?

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

    func quarantineAndStartFresh() {
        let bad = VoicePopPaths.replacements.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: VoicePopPaths.replacements, to: bad)
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
        persist { self.add(from: from, to: to) }
        return nil
    }

    @discardableResult
    func update(original: Replacement, to: String) -> ReplacementValidationError? {
        if let error = Replacements.validate(from: original.from, to: to, existing: replacements.entries, excluding: original.from) {
            return error
        }
        guard let idx = replacements.entries.firstIndex(where: { $0.from == original.from }) else { return nil }
        replacements.entries[idx].to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = replacements.entries
        persist { self.update(original: original, to: to) }
        return nil
    }

    func delete(_ entry: Replacement) {
        replacements.entries.removeAll { $0.from == entry.from }
        entries = replacements.entries
        persist { self.delete(entry) }
    }

    func retrySave() {
        lastAction?()
    }

    /// Saves, and on failure keeps the in-memory edit (already applied to `entries` by the
    /// caller) so the UI never discards what the user typed - only Retry re-attempts the write.
    private func persist(retry: @escaping () -> Void) {
        lastAction = retry
        do {
            try replacements.save()
            saveError = nil
        } catch {
            saveError = "Couldn\u{2019}t save learned words. \(error.localizedDescription)"
        }
    }
}
