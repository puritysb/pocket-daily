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
    var search: String = ""
    @State private var editing: ArticleRecord?
    @State private var deleting: ArticleSummary?
    @State private var error: String?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button("New articles") { inbox.filter = .unread }
                    Button("Saved articles") { inbox.filter = .saved }
                    Button("All articles") { inbox.filter = .all }
                    if !inbox.feeds.isEmpty {
                        Divider()
                        ForEach(inbox.feeds) { feed in
                            Button(feed.title) { inbox.filter = .feed(feed.id) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(inbox.filterTitle).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("article-filter")
                Spacer()
                if inbox.isRefreshing {
                    ProgressView().controlSize(.small)
                    Button("Stop", systemImage: "stop.circle") { inbox.cancelRefresh() }.labelStyle(.iconOnly)
                } else if !inbox.feeds.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") { inbox.refresh() }
                        .labelStyle(.iconOnly).disabled(model.isDemoMode)
                        .accessibilityIdentifier("article-refresh")
                }
            }
            .buttonStyle(.plain).tint(.primary)
            .padding(.horizontal, 24).padding(.bottom, 12)

            List {
                if busy { ProgressView("Preparing article…") }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                if let error = error ?? inbox.error ?? library.error { Text(error).font(.callout).foregroundStyle(.red) }
                if inbox.failedFeeds > 0 {
                    Button { managingFeeds = true } label: {
                        Label("Some subscriptions could not refresh. Tap to review and retry.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.callout)
                    }.buttonStyle(.plain)
                }
                ForEach(inbox.visibleArticles.filter { search.isEmpty || $0.title.localizedStandardContains(search) || $0.preview.localizedStandardContains(search) }) { article in
                    HStack(alignment: .top, spacing: 12) {
                        Button { article.hasText ? open(article) : review(article.id) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    if !article.isRead { Circle().fill(PocketPalette.ink).frame(width: 5, height: 5) }
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
                            Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.primary)
                        .accessibilityLabel("Options for " + article.title)
                        .accessibilityIdentifier("article-options-" + article.title)
                        .disabled(busy)
                    }
                    .padding(.vertical, 12)
                    .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
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
                if inbox.visibleArticles.isEmpty && !busy && error == nil && inbox.error == nil && inbox.failedFeeds == 0 {
                    ContentUnavailableView {
                        Label(inbox.filter == .saved ? "Keep something worth returning to" : "Room for a good read", systemImage: "doc.text")
                    } description: {
                        Text(inbox.filter == .saved ? "Choose Save for later in an article’s menu. Reading and saving are separate, so your favourites stay here." :
                            "Follow a publication or save a link with +. Read articles stay in All articles, ready whenever you need them.")
                            .frame(maxWidth: 480)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("article-empty-state")
                }
            }
        }
        // The same measure as the Library header and the book grid, so the
        // filter and the rows share one left edge on wide windows.
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
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
        Button(article.isArchived ? "Remove from saved" : "Save for later", systemImage: article.isArchived ? "bookmark.slash" : "bookmark") {
            Task { await inbox.setArchived(article, !article.isArchived) }
        }
        Button(article.isRead ? "Mark as unread" : "Mark as read", systemImage: "checkmark") {
            Task { await inbox.setRead(article, !article.isRead) }
        }
        Button(article.hasText ? "Edit article" : "Get full text", systemImage: "pencil") { review(article.id) }
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
