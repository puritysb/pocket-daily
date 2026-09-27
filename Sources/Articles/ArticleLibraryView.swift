import SwiftUI

struct ArticleLibraryView: View {
    @ObservedObject var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var articles: [ArticleSummary] = []
    @State private var adding = false
    @State private var editing: ArticleRecord?
    @State private var deleting: ArticleSummary?
    @State private var error: String?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Save articles here while browsing. Prepare the ones you want, then connect your reader and send them from Files.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if busy { ProgressView("Preparing article…") }
                if let notice { Text(notice).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
                if articles.isEmpty { Text("No articles yet. Use Share → Pocket Daily in your browser, or add a link or text here.") }
                ForEach(articles) { article in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(article.title).font(.headline)
                        Text(URL(string: article.source)?.host ?? "Saved text").font(.caption).foregroundStyle(.secondary)
                        Text(!article.hasText ? "Link saved · get the text before sending" : article.preview).lineLimit(3).font(.callout)
                        HStack {
                            Button("Review") { review(article.id) }.disabled(busy)
                            Button("Prepare for reader") { prepare(article) }
                                .disabled(busy || !model.canPrepareFiles || !article.hasText)
                            Spacer()
                            Button("Delete", role: .destructive) { deleting = article }.disabled(busy)
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                }
            }
            .navigationTitle("Articles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .primaryAction) { Button("Add article") { adding = true }.disabled(busy || model.isDemoMode) }
            }
            .sheet(isPresented: $adding, onDismiss: { Task { await reload() } }) {
                ArticleCaptureView(initialURL: "", completed: {})
            }
            .sheet(item: $editing, onDismiss: { Task { await reload() } }) { article in
                ArticleCaptureView(initialURL: article.source, existing: article, completed: {})
            }
            .confirmationDialog("Delete from this app? The reader copy is kept.", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    if let article = deleting {
                        Button("Delete \(article.title)", role: .destructive) {
                            Task {
                                do { try await ArticleStore.shared.remove(article.id); await reload() }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
            }
        }
        .task { await reload() }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await reload() } }
        }
        .interactiveDismissDisabled(busy)
#if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
#endif
    }
    private func reload() async {
        do { articles = try await ArticleStore.shared.summaries(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func review(_ id: UUID) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { editing = try await ArticleStore.shared.load(id) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func prepare(_ article: ArticleSummary) {
        guard !model.preparedTransfers.contains(where: { $0.filename == "pd-article-\(article.id.uuidString.lowercased()).epub" }) else {
            notice = "This article is already ready in Files. Choose Send after connecting."
            return
        }
        busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            var export: URL?
            do {
                let record = try await ArticleStore.shared.load(article.id)
                let url = try await ArticleEPUB.write(record)
                export = url
                try await model.prepareGeneratedReadingFile(url)
                try await ReadingDocumentPreparation.removeExport(at: url)
                export = nil
                notice = "Ready in Files. Connect the reader, then choose Send. Sending again replaces the same article; deleted reader copies are never sent automatically."
            } catch {
                self.error = error.localizedDescription
                if let export {
                    do { try await ReadingDocumentPreparation.removeExport(at: export) }
                    catch { self.error = "\(self.error ?? "") Temporary export cleanup also failed: \(error.localizedDescription)" }
                }
            }
        }
    }
}
