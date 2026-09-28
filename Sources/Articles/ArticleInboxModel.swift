import SwiftUI

@MainActor
final class ArticleInboxModel: ObservableObject {
    enum Filter: Hashable {
        case unread, saved, all, feed(UUID)
        var title: String {
            switch self {
            case .unread: "New articles"
            case .saved: "Saved articles"
            case .all: "All articles"
            case .feed: "Subscription"
            }
        }
    }

    static let shared: ArticleInboxModel = {
#if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-feeds=") }) {
            let token = String(argument.dropFirst("--ui-test-feeds=".count)).filter { $0.isLetter || $0.isNumber || $0 == "-" }
            return ArticleFeedPreview.inbox(root: URL.applicationSupportDirectory.appendingPathComponent("FeedTests/" + token))
        }
#endif
        return ArticleInboxModel()
    }()
    @Published private(set) var articles: [ArticleSummary] = []
    @Published private(set) var feeds: [ArticleFeed] = []
    @Published private(set) var isRefreshing = false
    @Published var filter: Filter = .unread
    @Published var error: String?
    let store: ArticleStore
    private let subscriptions: ArticleFeedStore
    private var work: Task<Void, Never>?
    private var subscriptionTask: Task<UUID, Error>?
    private var lastAttempt: Date?
    private var networkAllowed = true

    init(store: ArticleStore = .shared, subscriptions: ArticleFeedStore = .shared) {
        self.store = store; self.subscriptions = subscriptions
    }

    var filterTitle: String {
        if case .feed(let id) = filter { return feeds.first { $0.id == id }?.title ?? "Subscription" }
        return filter.title
    }
    var visibleArticles: [ArticleSummary] {
        articles.filter {
            switch filter {
            case .unread: !$0.isRead && !$0.isArchived
            case .saved: $0.isArchived
            case .all: true
            case .feed(let id): $0.feedID == id
            }
        }
    }
    var failedFeeds: Int { feeds.filter { $0.lastError != nil }.count }

    func load() async {
        do {
            articles = try await store.summaries().sorted {
                ($0.publishedAt ?? $0.savedAt) > ($1.publishedAt ?? $1.savedAt)
            }
            feeds = try await subscriptions.subscriptions()
            if case .feed(let id) = filter, !feeds.contains(where: { $0.id == id }) { filter = .all }
        } catch { self.error = error.localizedDescription }
    }

    func activate(allowNetwork: Bool) async {
        networkAllowed = allowNetwork
        if !allowNetwork { cancelRefresh() }
        await load()
        guard !Task.isCancelled, networkAllowed, allowNetwork, !feeds.isEmpty, lastAttempt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        refresh()
    }

    func refresh() {
        guard networkAllowed, !isRefreshing else { return }
        isRefreshing = true; error = nil; lastAttempt = Date()
        work = Task {
            defer { isRefreshing = false; work = nil }
            do { try await subscriptions.refresh() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            await load()
        }
    }
    func cancelRefresh() { work?.cancel(); subscriptionTask?.cancel() }
    func suspend() { networkAllowed = false; cancelRefresh() }

    func subscribe(_ url: String) async throws {
        guard networkAllowed else { throw ArticleFeedError.networkDisabled }
        guard !isRefreshing else { throw ArticleFeedError.busy }
        isRefreshing = true
        let task = Task { try await subscriptions.subscribe(url) }
        subscriptionTask = task
        defer { isRefreshing = false; subscriptionTask = nil }
        do {
            let id = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            await load()
            filter = .feed(id)
        } catch {
            await load()
            throw error
        }
    }
    func unsubscribe(_ feed: ArticleFeed) async {
        do { try await subscriptions.unsubscribe(feed.id); await load() }
        catch { self.error = error.localizedDescription }
    }
    func setRead(_ article: ArticleSummary, _ read: Bool) async {
        do { try await store.setRead(article.id, read); await load() }
        catch { self.error = error.localizedDescription }
    }
    func setArchived(_ article: ArticleSummary, _ archived: Bool) async {
        do { try await store.setArchived(article.id, archived); await load() }
        catch { self.error = error.localizedDescription }
    }
}
