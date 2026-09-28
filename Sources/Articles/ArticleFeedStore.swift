import Foundation

struct ArticleFeedClient: Sendable {
    var feed: @Sendable (String) async throws -> ParsedArticleFeed
    var article: @Sendable (String) async throws -> String

    static let live = ArticleFeedClient(feed: { source in
        let response = try await ArticleExtraction.download(source, accept: "application/atom+xml, application/rss+xml, application/xml, text/xml")
        let worker = Task.detached(priority: .utility) {
            try ArticleFeedParser.parse(response.data, source: response.url)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }, article: { try await ArticleExtraction.fetch($0).text })
}

/// Subscriptions are app-owned; article files remain in the app/share-extension store.
/// Downloading or removing a subscription never transfers/deletes a reader copy.
actor ArticleFeedStore {
    static let shared = ArticleFeedStore()
    private let file: URL
    private let articles: ArticleStore
    private let client: ArticleFeedClient
    private var refreshing = false

    init(root: URL? = nil, articles: ArticleStore = .shared, client: ArticleFeedClient = .live) {
        let folder = root ?? URL.applicationSupportDirectory.appendingPathComponent("Pocket/Feeds", isDirectory: true)
        self.file = folder.appendingPathComponent("subscriptions.json")
        self.articles = articles
        self.client = client
    }

    func subscriptions() throws -> [ArticleFeed] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 1024 * 1024 else { throw ArticleError.tooLarge }
        let feeds = try JSONDecoder().decode([ArticleFeed].self, from: data)
        guard feeds.count <= 50 else { throw ArticleFeedError.limit }
        for feed in feeds { _ = try ArticleRecord.sourceURL(feed.url) }
        return feeds
    }

    func subscribe(_ source: String) async throws -> UUID {
        try Task.checkCancellation()
        guard !refreshing else { throw ArticleFeedError.busy }
        refreshing = true
        defer { refreshing = false }
        let url = ArticleFeedParser.canonical(try ArticleRecord.sourceURL(source)).absoluteString
        try checkNew(url)
        let parsed = try await client.feed(url)
        try Task.checkCancellation()
        // Re-read after the network suspension so changes to other subscriptions are retained.
        try checkNew(url)
        let feed = ArticleFeed(id: ArticleFeedParser.identity("feed\n" + url), url: url, title: parsed.title)
        try save(try subscriptions() + [feed])
        do {
            var sources = try await knownSources()
            _ = try await importEntries(parsed, into: feed, sources: &sources)
        } catch {
            // A failed first import leaves no subscription behind, so adding it again works.
            try? unsubscribe(feed.id)
            throw error
        }
        return feed.id
    }

    func unsubscribe(_ id: UUID) throws {
        try save(try subscriptions().filter { $0.id != id })
    }

    /// Successful feeds remain usable when another fails. Per-feed errors are persisted.
    func refresh() async throws {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let feeds = try subscriptions()
        guard !feeds.isEmpty else { return }
        // Read once per refresh; every feed adds what it publishes to the same set.
        var sources = try await knownSources()
        for feed in feeds {
            try Task.checkCancellation()
            do {
                let parsed = try await client.feed(feed.url)
                try Task.checkCancellation()
                _ = try await importEntries(parsed, into: feed, sources: &sources)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                try recordFailure(feed.id, error)
            }
        }
    }

    private func knownSources() async throws -> Set<String> {
        Set(try await articles.summaries().compactMap { summary -> String? in
            guard let url = URL(string: summary.source), !summary.source.isEmpty else { return nil }
            return ArticleFeedParser.canonical(url).absoluteString
        })
    }

    private func importEntries(_ parsed: ParsedArticleFeed, into feed: ArticleFeed,
                               sources: inout Set<String>) async throws -> Int {
        guard try subscriptions().contains(where: { $0.id == feed.id }) else { return 0 }
        var pending: [FeedEntry] = []
        for entry in parsed.entries.prefix(20) {
            if try await articles.containsOrDeleted(entry.id) { continue }
            if !entry.source.isEmpty {
                if try await articles.containsOrDeleted(ArticleFeedParser.identity(entry.source)) { continue }
                if !sources.insert(entry.source).inserted { continue }
            }
            pending.append(entry)
        }
        var imported = 0
        // At most three page requests in flight; feed-provided bodies need no extra request.
        let client = client
        try await withThrowingTaskGroup(of: ArticleRecord.self) { group in
            var next = pending.makeIterator()
            func enqueue(_ entry: FeedEntry) {
                group.addTask {
                    var record = ArticleRecord(id: entry.id, title: entry.title,
                                               source: entry.source.isEmpty ? feed.url : entry.source,
                                               text: entry.text, feedID: feed.id, feedTitle: parsed.title,
                                               publishedAt: entry.publishedAt, summary: entry.summary,
                                               sourceIdentity: entry.source.isEmpty ? nil : ArticleFeedParser.identity(entry.source))
                    if record.text.isEmpty, !entry.source.isEmpty {
                        do { record.text = try await client.article(entry.source) }
                        catch {
                            if Task.isCancelled { throw CancellationError() }
                            record.downloadError = "The full text could not be saved. Open this article to retry or paste the text."
                        }
                    }
                    try Task.checkCancellation()
                    return record
                }
            }
            for _ in 0..<3 { if let entry = next.next() { enqueue(entry) } }
            while let record = try await group.next() {
                try Task.checkCancellation()
                // Unsubscribing while requests are in flight must stop publication.
                guard try subscriptions().contains(where: { $0.id == feed.id }) else { group.cancelAll(); return }
                if try await articles.insertFromFeed(record) { imported += 1 }
                if let entry = next.next() { enqueue(entry) }
            }
        }
        var feeds = try subscriptions()
        if let index = feeds.firstIndex(where: { $0.id == feed.id }) {
            feeds[index].title = parsed.title
            feeds[index].lastRefreshedAt = Date()
            feeds[index].lastError = nil
            try save(feeds)
        }
        return imported
    }

    private func recordFailure(_ id: UUID, _ error: Error) throws {
        var feeds = try subscriptions()
        if let index = feeds.firstIndex(where: { $0.id == id }) {
            feeds[index].lastError = error.localizedDescription
            try save(feeds)
        }
    }
    private func checkNew(_ url: String) throws {
        let feeds = try subscriptions()
        guard !feeds.contains(where: { $0.url == url }) else { throw ArticleFeedError.duplicate }
        guard feeds.count < 50 else { throw ArticleFeedError.limit }
    }
    private func save(_ feeds: [ArticleFeed]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(feeds).write(to: file, options: .atomic)
    }
}
