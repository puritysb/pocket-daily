import XCTest
@testable import Pocket

final class ArticleFeedTests: XCTestCase {
    private let source = URL(string: "https://example.org/feed.xml")!

    func testRSSFullTextSummaryDatesNamespacesAndDuplicateGUIDs() throws {
        let parsed = try parse("""
        <rss version="2.0" xmlns:c="http://purl.org/rss/1.0/modules/content/" xmlns:fake="https://fake.example">
        <channel><title>A &amp; B</title>
        <item><title>Older</title><guid isPermaLink="false">old</guid><link>/older#top</link>
        <pubDate>Mon, 28 Sep 2026 07:00:00 GMT</pubDate><description>&lt;p&gt;Only a preview&lt;/p&gt;</description></item>
        <item><title>한글 &amp; New</title><guid isPermaLink="false">new</guid><link>/new</link>
        <pubDate>Mon, 28 Sep 2026 08:00:00 GMT</pubDate><fake:encoded>Wrong namespace</fake:encoded>
        <c:encoded><![CDATA[<p>Full <b>text</b>.</p><script>bad()</script><p>Second.</p>]]></c:encoded></item>
        <item><title>Duplicate</title><guid isPermaLink="false">new</guid><link>/new</link></item>
        </channel></rss>
        """)
        XCTAssertEqual(parsed.title, "A & B")
        XCTAssertEqual(parsed.entries.count, 2)
        XCTAssertEqual(parsed.entries[0].title, "한글 & New")
        XCTAssertEqual(parsed.entries[0].text, "Full text.\n\nSecond.")
        XCTAssertEqual(parsed.entries[1].source, "https://example.org/older")
        XCTAssertEqual(parsed.entries[1].text, "")
        XCTAssertEqual(parsed.entries[1].summary, "Only a preview")
    }

    func testAtomHTMLXHTMLPlainTextRelativeBaseAndAlternateLinks() throws {
        let parsed = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://example.org/journal/">
        <title type="html">The &lt;b&gt;Journal&lt;/b&gt;</title>
        <entry><id>tag:example.org,2026:a</id><title type="html">A &amp;amp; B</title>
        <link rel="enclosure" href="image.jpg"/><link rel="alternate" href="first"/>
        <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Hello <b>world</b>.</p><p>Next.</p><script>bad()</script></div></content></entry>
        <entry><id>second</id><title>Plain</title><content type="text">1 &lt; 2 &amp; 3</content></entry>
        <entry><id>third</id><title>External content</title><link href="third"/><content src="file:///etc/passwd"/><summary type="html">&lt;p&gt;Preview&lt;/p&gt;</summary></entry>
        </feed>
        """)
        XCTAssertEqual(parsed.title, "The Journal")
        XCTAssertEqual(parsed.entries.count, 3)
        XCTAssertEqual(parsed.entries[0].title, "A & B")
        XCTAssertEqual(parsed.entries[0].source, "https://example.org/journal/first")
        XCTAssertEqual(parsed.entries[0].text, "Hello world.\n\nNext.")
        XCTAssertEqual(parsed.entries[1].text, "1 < 2 & 3")
        XCTAssertEqual(parsed.entries[2].text, "")
        XCTAssertEqual(parsed.entries[2].summary, "Preview")
    }

    func testRejectsMalformedDTDUnsupportedAndExcessiveFeeds() throws {
        for xml in ["<rss><channel>", "<html><body>Not a feed</body></html>",
                    "<feed><title>Wrong namespace</title></feed>",
                    "<!DOCTYPE rss [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><rss><channel><title>&secret;</title></channel></rss>",
                    "<rss><channel>" + String(repeating: "<deep>", count: 65) + String(repeating: "</deep>", count: 65) + "</channel></rss>"] {
            XCTAssertThrowsError(try parse(xml))
        }
        XCTAssertThrowsError(try ArticleFeedParser.parse(Data(repeating: 65, count: ArticleExtraction.maximumBytes + 1), source: source))
    }

    func testSelfContainedRSSDescriptionCanBeReadWithoutAnArticleLink() throws {
        let parsed = try parse("<rss><channel><title>Letters</title><item><title>A letter</title><description>&lt;p&gt;The complete letter.&lt;/p&gt;</description></item></channel></rss>")
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries[0].text, "The complete letter.")
        XCTAssertEqual(parsed.entries[0].source, "")
    }

    func testUnsafeLinksAreNeverFetchedAndTitlesFitFirmwareMetadata() throws {
        let parsed = try parse("""
        <rss><channel><title>Test</title>
        <item><title>Unsafe</title><link>http://example.org/unsafe</link><description>Preview</description></item>
        <item><title>Secret</title><link>https://user:password@example.org</link></item>
        <item><title>\(String(repeating: "한", count: 150))</title><link>https://example.org/long</link></item>
        </channel></rss>
        """)
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertLessThanOrEqual(parsed.entries[0].title.utf8.count, 256)
    }

    func testLatestTwentyAndStableIdentityAcrossContentChanges() throws {
        let items = (1...30).map { "<item><title>Item \($0)</title><guid isPermaLink='false'>\($0)</guid><link>https://example.org/\($0)</link><pubDate>Mon, \($0) Sep 2026 08:00:00 GMT</pubDate></item>" }.joined()
        let parsed = try parse("<rss><channel><title>Feed</title>" + items + "</channel></rss>")
        XCTAssertEqual(parsed.entries.count, 20)
        XCTAssertEqual(parsed.entries.first?.title, "Item 30")
        let edited = try parse("<rss><channel><title>Edited</title>" + items.replacingOccurrences(of: "Item", with: "Revised") + "</channel></rss>")
        XCTAssertEqual(parsed.entries.map(\.id), edited.entries.map(\.id))
    }

    func testLegacyRecordsDecodeAndFlagsDoNotChangeEPUBBytes() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let record = try JSONDecoder().decode(ArticleRecord.self, from: Data("""
        {"id":"\(id)","title":"Legacy","source":"","text":"Readable offline.","savedAt":0}
        """.utf8))
        XCTAssertNil(record.readAt); XCTAssertNil(record.archivedAt); XCTAssertNil(record.feedID)
        let articles = ArticleStore(root: root)
        try await articles.save(record)
        let before = try await ArticleEPUB.write(record)
        defer { try? FileManager.default.removeItem(at: before.deletingLastPathComponent()) }
        try await articles.setRead(id, true)
        try await articles.setArchived(id, true)
        let reloaded = try await ArticleStore(root: root).load(id)
        XCTAssertNotNil(reloaded.readAt); XCTAssertNotNil(reloaded.archivedAt)
        let after = try await ArticleEPUB.write(reloaded)
        defer { try? FileManager.default.removeItem(at: after.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: before), try Data(contentsOf: after))
    }

    func testSubscriptionRefreshRetainsEditsFlagsAndDeletionAcrossRelaunchAndResubscribe() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let fixture = parsedFixture()
        let client = ArticleFeedClient(feed: { _ in fixture }, article: { _ in "Downloaded original." })
        let feedRoot = root.appendingPathComponent("feeds")
        let feeds = ArticleFeedStore(root: feedRoot, articles: articles, client: client)
        let id = try await feeds.subscribe(source.absoluteString)
        let initial = try await articles.summaries()
        XCTAssertEqual(initial.count, 2)
        XCTAssertTrue(initial.allSatisfy(\.hasText))
        var first = try await articles.load(fixture.entries[0].id)
        first.text = "User edited this."; first.readAt = Date(); first.archivedAt = Date()
        try await articles.save(first)
        try await articles.remove(fixture.entries[1].id)
        let relaunched = ArticleFeedStore(root: feedRoot, articles: articles, client: client)
        try await relaunched.refresh()
        let kept = try await articles.load(first.id)
        XCTAssertEqual(kept, first)
        let after = try await articles.summaries()
        XCTAssertEqual(after.count, 1)
        try await relaunched.unsubscribe(id)
        let remaining = try await articles.summaries()
        XCTAssertEqual(remaining.count, 1)
        _ = try await relaunched.subscribe(source.absoluteString)
        let resubscribed = try await articles.summaries()
        XCTAssertEqual(resubscribed.count, 1)
    }

    func testDeletedURLDoesNotReappearWithChangedGUID() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let fixture = parsedFixture()
        let feedRoot = root.appendingPathComponent("feeds")
        let feeds = ArticleFeedStore(root: feedRoot, articles: articles, client: .init(feed: { _ in fixture }, article: { _ in "Full text" }))
        _ = try await feeds.subscribe(source.absoluteString)
        try await articles.remove(fixture.entries[0].id)
        let changed = ParsedArticleFeed(title: fixture.title, entries: [FeedEntry(id: UUID(), title: "Changed GUID", source: fixture.entries[0].source, text: "Republished", summary: "", publishedAt: nil)])
        let relaunched = ArticleFeedStore(root: feedRoot, articles: articles, client: .init(feed: { _ in changed }, article: { _ in "Full text" }))
        try await relaunched.refresh()
        let after = try await articles.summaries()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, fixture.entries[1].id)
    }

    func testFailedExtractionPreservesSummaryWithoutPretendingItIsOfflineText() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let fixture = parsedFixture()
        let feeds = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { _ in fixture }, article: { _ in throw ArticleError.unreadable }))
        _ = try await feeds.subscribe(source.absoluteString)
        let missing = try await articles.load(fixture.entries[1].id)
        XCTAssertEqual(missing.text, "")
        XCTAssertEqual(missing.summary, "Summary only")
        XCTAssertNotNil(missing.downloadError)
        let good = try await articles.load(fixture.entries[0].id)
        XCTAssertEqual(good.text, "Full feed text")
    }

    func testRefreshFailureIsPerFeedAndPreservesOfflineCopies() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let fixture = parsedFixture()
        let feeds = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { _ in fixture }, article: { _ in "Original" }))
        _ = try await feeds.subscribe(source.absoluteString)
        _ = try await feeds.subscribe("https://other.example/feed")
        let relaunched = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { url in
            if url.contains("other.example") { return fixture }
            throw URLError(.notConnectedToInternet)
        }, article: { _ in "Original" }))
        try await relaunched.refresh()
        let subscriptions = try await relaunched.subscriptions()
        XCTAssertNotNil(subscriptions[0].lastError)
        XCTAssertNil(subscriptions[1].lastError)
        let offline = try await articles.summaries()
        XCTAssertEqual(offline.count, 2)
    }

    func testDuplicateSubscriptionCanonicalizationAndManualArticleDeduplication() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let fixture = parsedFixture()
        try await articles.save(ArticleRecord(title: "Manual", source: fixture.entries[0].source + "#top", text: "Saved manually"))
        let feeds = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { _ in fixture }, article: { _ in "Original" }))
        _ = try await feeds.subscribe("https://EXAMPLE.org:443/feed.xml#top")
        do { _ = try await feeds.subscribe(source.absoluteString); XCTFail("Duplicate accepted") }
        catch { XCTAssertTrue(error is ArticleFeedError) }
        let saved = try await articles.summaries()
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.contains { $0.title == "Manual" })
    }

    @MainActor
    func testInboxReadAndSavedFiltersAreIndependent() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let record = ArticleRecord(title: "Keep", source: "", text: "Offline")
        try await articles.save(record)
        let model = ArticleInboxModel(store: articles, subscriptions: ArticleFeedStore(root: root, articles: articles))
        await model.load()
        XCTAssertEqual(model.visibleArticles.count, 1)
        await model.setArchived(ArticleSummary(record), true)
        XCTAssertEqual(model.visibleArticles.count, 0)
        model.filter = .saved
        XCTAssertEqual(model.visibleArticles.count, 1)
        await model.setRead(model.visibleArticles[0], true)
        XCTAssertEqual(model.visibleArticles.count, 1)
        model.filter = .all
        XCTAssertEqual(model.visibleArticles.count, 1)
    }

    func testCancellingRefreshLeavesExistingOfflineArticlesIntact() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let fixture = parsedFixture()
        let initial = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { _ in fixture }, article: { _ in "Original" }))
        _ = try await initial.subscribe(source.absoluteString)
        let started = expectation(description: "Feed request started")
        let slow = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return fixture
        }, article: { _ in "Original" }))
        let work = Task { try await slow.refresh() }
        await fulfillment(of: [started], timeout: 3)
        work.cancel()
        do { try await work.value; XCTFail("Refresh should cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await articles.summaries()
        XCTAssertEqual(saved.count, 2)
    }

    @MainActor
    func testDemoActivationDoesNotFetchSubscribedFeeds() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let fixture = parsedFixture()
        let initial = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { _ in fixture }, article: { _ in "Original" }))
        _ = try await initial.subscribe(source.absoluteString)
        let offline = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { _ in
            XCTFail("Demo mode made a feed request")
            throw ArticleError.unreadable
        }, article: { _ in XCTFail("Demo mode made a page request"); return "" }))
        let model = ArticleInboxModel(store: articles, subscriptions: offline)
        await model.activate(allowNetwork: false)
        XCTAssertEqual(model.articles.count, 2)
        XCTAssertFalse(model.isRefreshing)
        model.refresh()
        XCTAssertFalse(model.isRefreshing)
        do { try await model.subscribe("https://example.org/new"); XCTFail("Demo allowed subscribing") }
        catch { XCTAssertTrue(error is ArticleFeedError) }
    }

    @MainActor
    func testBackgroundingCancelsAnInFlightSubscription() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let fixture = parsedFixture()
        let started = expectation(description: "Subscription page request started")
        let feeds = ArticleFeedStore(root: root, articles: articles, client: .init(feed: { _ in fixture }, article: { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return "Original"
        }))
        let model = ArticleInboxModel(store: articles, subscriptions: feeds)
        let work = Task { try await model.subscribe("https://example.org/feed") }
        await fulfillment(of: [started], timeout: 3)
        model.suspend()
        do { try await work.value; XCTFail("Background subscription should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(model.isRefreshing)
    }

    private func parse(_ xml: String) throws -> ParsedArticleFeed { try ArticleFeedParser.parse(Data(xml.utf8), source: source) }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func parsedFixture() -> ParsedArticleFeed {
        ParsedArticleFeed(title: "Journal", entries: [
            FeedEntry(id: UUID(), title: "Full", source: "https://example.org/full", text: "Full feed text", summary: "", publishedAt: nil),
            FeedEntry(id: UUID(), title: "Excerpt", source: "https://example.org/excerpt", text: "", summary: "Summary only", publishedAt: nil)
        ])
    }
}
