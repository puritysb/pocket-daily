import SwiftUI

struct ArticleCaptureView: View {
    let initialURL: String
    var initialText: String = ""
    var existing: ArticleRecord? = nil
    var initialError: String? = nil
    var store: ArticleStore = .shared
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var title = ""
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @State private var saving = false
    @State private var work: Task<Void, Never>?
    @State private var identity = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section("Article link") {
                    TextField("https://…", text: $source).disabled(busy).accessibilityIdentifier("article-url")
                    Button("Get article text") { fetch() }.disabled(busy || source.isEmpty)
                }
                Section("Check the text before saving") {
                    TextField("Title", text: $title).accessibilityIdentifier("article-title")
                    TextEditor(text: $text).frame(minHeight: 240).accessibilityIdentifier("article-body")
                    Text("Check for missing text or unrelated page content. You can paste selected text here. Images and page styling are not included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(busy)
                if busy { ProgressView("Preparing article…") }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("article-error") }
            }
            .formStyle(.grouped)
            .navigationTitle("Save an article")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { work?.cancel(); dismiss(); completed() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(text.isEmpty ? "Save link" : "Save") { save() }.disabled(busy || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source.isEmpty))
                        .accessibilityIdentifier("article-save")
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .onAppear {
            error = initialError
            source = existing?.source ?? initialURL; text = existing?.text ?? initialText
            title = existing?.title ?? ""; identity = existing?.id ?? identity
            if existing == nil, !initialURL.isEmpty, initialText.isEmpty { fetch() }
        }
        .onDisappear { work?.cancel() }
#if os(macOS)
        .frame(minWidth: 500, minHeight: 560)
#endif
    }
    private func fetch() {
        busy = true; error = nil
        let url = source
        work = Task { @MainActor in
            defer { busy = false }
            do {
                let article = try await ArticleExtraction.fetch(url)
                try Task.checkCancellation()
                title = article.title; text = article.text
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func save() {
        saving = true
        busy = true; error = nil
        var article = existing ?? ArticleRecord(id: identity, title: "", source: "", text: "")
        article.title = title.isEmpty ? (URL(string: source)?.host ?? "Article") : title
        article.source = source; article.text = text
        article.downloadError = nil
        work = Task { @MainActor in
            defer { busy = false; saving = false }
            do {
                try await store.save(article)
                dismiss(); completed()
            } catch { self.error = error.localizedDescription }
        }
    }
}
