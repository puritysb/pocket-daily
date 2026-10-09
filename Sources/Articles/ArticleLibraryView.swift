import SwiftUI

/// Saved articles inside the Library: read here, or prepare for the reader.
struct ArticleShelf: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var library: LibraryModel
    let read: (LibraryBook) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var inbox: ArticleInboxModel
    @Binding var adding: Bool
    @Binding var managingFeeds: Bool
    var sendToReader: ((LibraryBook) -> Void)? = nil
    @Binding var search: String
    var contentInset: CGFloat = PocketDesign.pageInset
    @State private var editing: ArticleRecord?
    @State private var deleting: ArticleSummary?
    @State private var error: String?
    @State private var busy = false
    @State private var notice: String?

    private var shownArticles: [ArticleSummary] {
        inbox.visibleArticles.filter { search.isEmpty || $0.title.localizedStandardContains(search) || $0.preview.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    // A picker, so the current filter carries a checkmark.
                    Picker("Show", selection: $inbox.filter) {
                        ForEach([ArticleInboxModel.Filter.unread, .saved, .all], id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    if !inbox.feeds.isEmpty {
                        Picker("Subscriptions", selection: $inbox.filter) {
                            ForEach(inbox.feeds) { feed in Text(feed.title).tag(ArticleInboxModel.Filter.feed(feed.id)) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(inbox.filterTitle).font(.headline).lineLimit(1)
                        PocketSymbol("chevron.down", role: .accessory)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("article-filter")
                Spacer()
                if inbox.isRefreshing {
                    ProgressView().controlSize(.small)
                    Button { inbox.cancelRefresh() } label: { PocketActionGlyph(name: "stop.circle") }
                        .accessibilityLabel("Stop Refreshing")
                } else if !inbox.feeds.isEmpty {
                    Button { inbox.refresh() } label: { PocketActionGlyph(name: "arrow.clockwise") }
                        .accessibilityLabel("Refresh").disabled(model.isDemoMode)
                        .accessibilityIdentifier("article-refresh")
                }
            }
            .buttonStyle(.plain).tint(.primary)
            .padding(.horizontal, contentInset).padding(.bottom, 8)

            List {
                if busy { ProgressView("Preparing article…") }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                if let message = error ?? inbox.error ?? library.error {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        PocketStatusLabel(message, tone: .failure).font(.callout)
                        Spacer(minLength: 0)
                        Button("Dismiss") { error = nil; inbox.error = nil; library.error = nil }
                            .buttonStyle(.borderless).font(.callout)
                    }
                    .listRowBackground(Color.clear)
                }
                if inbox.failedFeeds > 0 {
                    Button { managingFeeds = true } label: {
                        Label("Some subscriptions could not refresh. Tap to review and retry.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.callout)
                    }.buttonStyle(.plain)
                }
                ForEach(shownArticles) { article in
                    HStack(alignment: .top, spacing: 12) {
                        Button { article.hasText ? open(article) : review(article.id) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    if !article.isRead {
                                        Circle().fill(PocketPalette.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                                        Text("New").fontWeight(.semibold).foregroundStyle(.primary)
                                        Text("·")
                                    }
                                    Text(article.feedTitle ?? URL(string: article.source)?.host ?? "Saved text")
                                        .lineLimit(1)
                                    Text("·")
                                    Text((article.publishedAt ?? article.savedAt).formatted(date: .abbreviated, time: .omitted))
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(article.title).font(.headline).foregroundStyle(.primary)
                                if !article.preview.isEmpty {
                                    Text(article.preview).lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    Label(article.hasText ? "Available offline" : "Link only · get full text",
                                          systemImage: article.hasText ? "arrow.down.circle" : "link")
                                    if article.isArchived { Label("Saved", systemImage: "bookmark.fill") }
                                    if article.isRead { Text("Read") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("Read " + article.title)
                        .disabled(busy)
                        Menu { actions(for: article) } label: {
                            PocketActionGlyph(name: "ellipsis")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.primary)
                        .accessibilityLabel("Options for " + article.title)
                        .accessibilityIdentifier("article-options-" + article.title)
                        .disabled(busy)
                    }
                    .padding(.vertical, 12)
                    .listRowInsets(EdgeInsets(top: 0, leading: contentInset, bottom: 0, trailing: contentInset))
                    .listRowBackground(Color.clear)
                    .contextMenu { actions(for: article) }
                    .swipeActions(edge: .leading) {
                        Button(article.isArchived ? "Unsave" : "Save", systemImage: article.isArchived ? "bookmark.slash" : "bookmark") {
                            Task { await inbox.setArchived(article, !article.isArchived) }
                        }.tint(PocketPalette.accent)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { deleting = article }
                        Button(article.isRead ? "Unread" : "Read") { Task { await inbox.setRead(article, !article.isRead) } }
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay {
                if shownArticles.isEmpty && !busy && error == nil && inbox.error == nil && inbox.failedFeeds == 0 {
                    if !search.isEmpty {
                        ContentUnavailableView {
                            Label("No articles match “\(search)”", systemImage: "magnifyingglass")
                        } actions: {
                            Button("Clear Search") { search = "" }.buttonStyle(.bordered)
                        }
                        .accessibilityIdentifier("article-search-empty")
                    } else {
                    ContentUnavailableView {
                        Label(inbox.filter == .saved ? "Keep something worth returning to" : "Room for a good read", systemImage: "doc.text")
                    } description: {
                        Text(inbox.filter == .saved ? "Choose Save for Later in an article’s menu. Saved articles stay here." :
                            "Follow a publication or save a link. Read articles stay in All Articles.")
                            .frame(maxWidth: 480)
                    } actions: {
                        // One next step: the empty filter leads back to the articles,
                        // an empty collection to adding one.
                        if inbox.filter == .saved {
                            Button("Show All Articles") { inbox.filter = .all }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Add Article") { adding = true }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("article-empty-add")
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("article-empty-state")
                    }
                }
            }
        }
        // The same measure as the Library header and the book grid, so the
        // filter and the rows share one left edge on wide windows.
        .frame(maxWidth: PocketDesign.contentWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $adding, onDismiss: { Task { await inbox.load() } }) {
            ArticleCaptureView(initialURL: "", store: inbox.store, completed: {})
        }
        .sheet(item: $editing, onDismiss: { Task { await inbox.load() } }) { article in
            ArticleCaptureView(initialURL: article.source, existing: article, initialError: article.downloadError, store: inbox.store, completed: {})
        }
        .sheet(isPresented: $managingFeeds) { ArticleSubscriptionsView(inbox: inbox, isDemo: model.isDemoMode) }
        .confirmationDialog("Delete this article? Its copy on the reader is kept.", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let article = deleting {
                    Button("Delete \(article.title)", role: .destructive) {
                        Task {
                            do {
                                try await inbox.store.remove(article.id)
                                if let book = book(for: article) { await library.remove(book) }
                                await inbox.load()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
        }
        .task { await inbox.load() }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await inbox.load() } }
        }
    }

    @ViewBuilder private func actions(for article: ArticleSummary) -> some View {
        Button(article.isArchived ? "Remove from Saved" : "Save for Later", systemImage: article.isArchived ? "bookmark.slash" : "bookmark") {
            Task { await inbox.setArchived(article, !article.isArchived) }
        }
        Button(article.isRead ? "Mark as Unread" : "Mark as Read", systemImage: "checkmark") {
            Task { await inbox.setRead(article, !article.isRead) }
        }
        Button(article.hasText ? "Edit Article" : "Get Full Text", systemImage: "pencil") { review(article.id) }
        Button("Send to Reader…", systemImage: "arrow.up.doc") { prepare(article) }
            .disabled(!article.hasText || sendToReader == nil)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = article }
    }

    private func book(for article: ArticleSummary) -> LibraryBook? {
        library.books.first { $0.origin == .article(article.id) }
    }

    private func open(_ article: ArticleSummary) {
        busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            if let book = await library.importArticle(article.id, store: inbox.store) {
                await inbox.setRead(article, true)
                read(book)
            }
            else { error = library.error }
        }
    }

    private func review(_ id: UUID) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { editing = try await inbox.store.load(id) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Sends the same EPUB the Library reads, so both devices see one book.
    private func prepare(_ article: ArticleSummary) {
        busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            guard let book = await library.importArticle(article.id, store: inbox.store) else {
                error = library.error
                return
            }
            sendToReader?(book)
        }
    }
}
