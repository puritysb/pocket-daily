#if DEBUG
import Foundation

/// Local publisher fixtures exercise the shipping parser, persistence and UI without a server.
/// Only previews and explicitly requested UI-test launches install this transport.
enum ArticleFeedPreview {
    @MainActor
    static func inbox(root: URL) -> ArticleInboxModel {
        let articles = ArticleStore(root: root.appendingPathComponent("articles"))
        let feeds = ArticleFeedStore(root: root.appendingPathComponent("feeds"), articles: articles, client: client)
        return ArticleInboxModel(store: articles, subscriptions: feeds)
    }

    static let client = ArticleFeedClient(feed: { source in
        let url = try ArticleRecord.sourceURL(source)
        guard url.host == "journal.example" else { throw ArticleFeedError.invalidFeed }
        return try ArticleFeedParser.parse(Data(xml.utf8), source: url)
    }, article: { source in
        if source.contains("link-only") { throw ArticleError.unreadable }
        return "A quiet morning begins with a little space. Put the phone aside, open a book, and let one idea hold your attention.\n\nReading slowly makes room for the details we tend to miss. A sentence can be enough to change the shape of a day."
    })

    static let xml = """
    <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel><title>The Quiet Journal</title><link>https://journal.example</link>
    <item><guid isPermaLink="false">morning</guid><title>A little room for a slower morning</title>
    <link>https://journal.example/morning</link><pubDate>Mon, 28 Sep 2026 08:00:00 GMT</pubDate>
    <content:encoded><![CDATA[<p>Before the day fills with messages and meetings, there is a small pocket of time that belongs to you.</p><p>Make a cup of tea. Find a comfortable chair. Read a few pages without keeping score.</p><p>The pleasure is in paying attention, one paragraph at a time.</p>]]></content:encoded></item>
    <item><guid isPermaLink="false">walking</guid><title>Notes from a familiar walk</title>
    <link>https://journal.example/walking</link><pubDate>Sun, 27 Sep 2026 08:00:00 GMT</pubDate>
    <description><![CDATA[<p>The same streets can tell a different story when we slow down enough to notice.</p>]]></description></item>
    <item><guid isPermaLink="false">books</guid><title>The books we return to</title>
    <link>https://journal.example/books</link><pubDate>Sat, 26 Sep 2026 08:00:00 GMT</pubDate>
    <content:encoded><![CDATA[<p>Some books feel like old friends. We return to them at different moments, finding something new in a passage we thought we knew.</p><p>Keep a place on the shelf for the stories that stay with you.</p>]]></content:encoded></item>
    <item><guid isPermaLink="false">link-only</guid><title>A letter for the weekend</title>
    <link>https://journal.example/link-only</link><pubDate>Fri, 25 Sep 2026 08:00:00 GMT</pubDate>
    <description><![CDATA[<p>A few things worth taking your time with this weekend.</p>]]></description></item>
    </channel></rss>
    """
}
#endif
