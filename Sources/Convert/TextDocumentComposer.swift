import SwiftUI

struct TextDocumentComposer: View {
    let prepare: (URL) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var title = ""
    @State private var text = ""
    @State private var format = ReadingDocumentFormat.epub
    @State private var error: String?
    @State private var phase = Phase.idle
    @State private var work: Task<Void, Never>?
    // Retained only if deletion failed, so retry never silently abandons an exported file.
    @State private var exportToRemove: URL?
    @State private var queued = false

    private enum Phase { case idle, creating, preparing }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("compose-title")
                    Picker("Format", selection: $format) {
                        ForEach(ReadingDocumentFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("compose-format")
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .accessibilityIdentifier("compose-text")
                } footer: {
                    Text(format == .epub
                         ? "Creates an EPUB with a table of contents. Long text is split into readable sections."
                         : "Creates a plain text file for the reader.")
                }
                .disabled(phase != .idle || queued)
                if phase != .idle {
                    ProgressView(phase == .creating ? "Creating your document…" : "Preparing an offline copy…")
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption).accessibilityIdentifier("compose-error") }
            }
            .formStyle(.grouped)
            .navigationTitle("Text to read")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if phase == .creating { work?.cancel() }
                        else { dismiss() }
                    }
                    .disabled(phase == .preparing || exportToRemove != nil)
                    .accessibilityIdentifier("compose-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(queued ? "Finish" : "Prepare") { write() }
                        .disabled(phase != .idle || (!queued && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("compose-prepare")
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
#endif
        .interactiveDismissDisabled(phase != .idle || exportToRemove != nil)
        .onDisappear { work?.cancel() }
        .onChange(of: scenePhase) { _, value in
            if value == .background, phase == .creating { work?.cancel() }
        }
    }

    private func write() {
        guard phase == .idle else { return }
        error = nil
        phase = .creating
        let title = title, text = text, format = format
        work = Task { @MainActor in
            defer { phase = .idle; work = nil }
            do {
                if let old = exportToRemove {
                    try await ReadingDocumentPreparation.removeExport(at: old)
                    exportToRemove = nil
                }
                if queued { dismiss(); return }
                let url = try await ReadingDocumentPreparation.create(title: title, text: text, format: format)
                exportToRemove = url
                try Task.checkCancellation()
                phase = .preparing
                try await prepare(url)
                queued = true
                try await ReadingDocumentPreparation.removeExport(at: url)
                exportToRemove = nil
                dismiss()
            } catch {
                let originalError = error
                if let url = exportToRemove {
                    do {
                        try await ReadingDocumentPreparation.removeExport(at: url)
                        exportToRemove = nil
                    } catch {
                        self.error = queued
                            ? "Your file is ready to send, but the temporary export could not be removed. Choose Finish to retry cleanup."
                            : "The temporary export could not be removed. Choose Prepare to retry cleanup. Your text is kept here."
                        return
                    }
                }
                // Never invite a second export when the first durable queue receipt already exists.
                if queued { dismiss() }
                else if !(originalError is CancellationError) { self.error = originalError.localizedDescription }
            }
        }
    }
}
