import SwiftUI

/// Written reading content belongs to the Library. Creation never prepares a
/// reader transfer; the book's normal Send action does that afterwards.
struct LibraryTextComposer: View {
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var error: String?
    @State private var working = false
    @State private var added = false
    @State private var export: URL?
    @State private var work: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).accessibilityIdentifier("compose-title")
                TextEditor(text: $text).frame(minHeight: 220).accessibilityIdentifier("compose-text")
                if working { ProgressView(added ? "Finishing…" : "Adding to Library…") }
                if let error { Text(error).font(.callout).foregroundStyle(PocketPalette.critical).accessibilityIdentifier("compose-error") }
            }
            .formStyle(.grouped)
            .navigationTitle("Write to Read")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working || export != nil)
                        .accessibilityIdentifier("compose-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(added ? "Finish" : "Add to Library") { save() }
                        .disabled(working || (!added && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("compose-save")
                }
            }
        }
        .interactiveDismissDisabled(working || export != nil)
#if os(macOS)
        .frame(width: 520, height: 600)
#endif
    }

    private func save() {
        guard !working else { return }
        working = true
        error = nil
        work = Task { @MainActor in
            defer { working = false; work = nil }
            do {
                if let export {
                    try await ReadingDocumentPreparation.removeExport(at: export)
                    self.export = nil
                }
                if added { dismiss(); return }
                let url = try await ReadingDocumentPreparation.create(title: title, text: text, format: .epub)
                export = url
                guard await library.importFiles([url]) != nil else {
                    throw NSError(domain: "LibraryTextComposer", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: library.error ?? "The book could not be added. Try again."])
                }
                added = true
                try await ReadingDocumentPreparation.removeExport(at: url)
                export = nil
                dismiss()
            } catch {
                if let export {
                    do {
                        try await ReadingDocumentPreparation.removeExport(at: export)
                        self.export = nil
                    } catch {
                        self.error = added
                            ? "Your book is in the Library. Choose Finish to retry removing its temporary export."
                            : "The temporary export could not be removed. Your text is kept here; try again."
                        return
                    }
                }
                if added { dismiss() } else { self.error = error.localizedDescription }
            }
        }
    }
}
