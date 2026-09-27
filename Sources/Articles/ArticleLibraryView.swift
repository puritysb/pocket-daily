import SwiftUI

/// Saved articles inside the Library: read here, or prepare for the reader.
struct ArticleShelf: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var library: LibraryModel
    let read: (LibraryBook) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var articles: [ArticleSummary] = []
    @State private var adding = false
    @State private var editing: ArticleRecord?
    @State private var deleting: ArticleSummary?
    @State private var error: String?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                Text("Save articles from the share sheet while browsing, or add a link or text here. Read them here, or prepare them for your reader.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Add article", systemImage: "plus") { adding = true }
                    .disabled(busy)
                    .accessibilityIdentifier("article-add")
            }
            if busy { ProgressView("Preparing article…") }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
            if articles.isEmpty {
                Text("No articles yet. Use Share → Pocket Daily in your browser, or add a link or text here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(articles) { article in
                VStack(alignment: .leading, spacing: 8) {
                    Text(article.title).font(.headline)
                    HStack(spacing: 6) {
                        Text(URL(string: article.source)?.host ?? "Saved text")
                        if let book = book(for: article), book.progress > 0 {
                            Text("· \(book.progress.formatted(.percent.precision(.fractionLength(0)))) read")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(!article.hasText ? "Link saved · get the text before reading" : article.preview)
                        .lineLimit(3).font(.callout)
                    HStack {
                        Button("Read") { open(article) }
                            .disabled(busy || !article.hasText)
                            .accessibilityIdentifier("Read " + article.title)
                        Button("Review") { review(article.id) }.disabled(busy)
                        Button("Prepare for reader") { prepare(article) }
                            .disabled(busy || !model.canPrepareFiles || !article.hasText)
                        Spacer()
                        Button("Delete", role: .destructive) { deleting = article }.disabled(busy)
                    }.buttonStyle(.borderless)
                }.padding(.vertical, 6)
            }
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await reload() } }) {
            ArticleCaptureView(initialURL: "", completed: {})
        }
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { article in
            ArticleCaptureView(initialURL: article.source, existing: article, completed: {})
        }
        .confirmationDialog("Delete this article? Its copy on the reader is kept.", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let article = deleting {
                    Button("Delete \(article.title)", role: .destructive) {
                        Task {
                            do {
                                try await ArticleStore.shared.remove(article.id)
                                if let book = book(for: article) { await library.remove(book) }
                                await reload()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
        }
        .task { await reload() }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await reload() } }
        }
    }

    private func book(for article: ArticleSummary) -> LibraryBook? {
        library.books.first { $0.origin == .article(article.id) }
    }

    private func reload() async {
        do { articles = try await ArticleStore.shared.summaries(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func open(_ article: ArticleSummary) {
        busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            if let book = await library.importArticle(article.id) { read(book) }
            else { error = library.error }
        }
    }

    private func review(_ id: UUID) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { editing = try await ArticleStore.shared.load(id) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Sends the same EPUB the Library reads, so both devices see one book.
    private func prepare(_ article: ArticleSummary) {
        guard !model.preparedTransfers.contains(where: { $0.filename == "pd-article-\(article.id.uuidString.lowercased()).epub" }) else {
            notice = "This article is already ready in Reader → Files. Choose Send after connecting."
            return
        }
        busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            guard let book = await library.importArticle(article.id) else {
                error = library.error
                return
            }
            do {
                let url = try await library.fileURL(for: book)
                guard let work = model.upload(url) else {
                    throw PocketModel.ReadingPreparationFailure.unavailable
                }
                await work.value
                notice = "Ready in Reader → Files. Connect the reader, then choose Send. Sending again replaces the same article; deleted reader copies are never sent automatically."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
