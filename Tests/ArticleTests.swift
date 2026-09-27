import XCTest
@testable import Pocket

final class ArticleTests: XCTestCase {
    func testFetchAcceptsHTMLAndRejectsHTTPFailuresTypesAndOversizeHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArticlePageProtocol.self]
        let article = try await ArticleExtraction.fetch("https://example.org/ok", configuration: configuration)
        XCTAssertEqual(article.text, "Local fixture text.")
        for route in ["denied", "image", "large"] {
            do {
                _ = try await ArticleExtraction.fetch("https://example.org/" + route, configuration: configuration)
                XCTFail("Expected rejection for " + route)
            } catch { XCTAssertTrue(error is ArticleError) }
        }
    }

    func testExtractsArticleWithoutNavigationScriptsAndResources() throws {
        let html = """
        <html><head><title>한글 &amp; Article</title></head><body><nav>Menu</nav>
        <article><h1>읽을 글</h1><p>Hello <b>world</b> &amp; 한글.</p><script>secret()</script>
        <p>Next<br>line<img src="https://invalid.example/image"></p><div hidden>Hidden</div></article><footer>Footer</footer></body></html>
        """
        let article = try ArticleExtraction.parse(Data(html.utf8), source: "https://example.org/article")
        XCTAssertEqual(article.title, "한글 & Article")
        XCTAssertEqual(article.text, "읽을 글\n\nHello world & 한글.\n\nNext\nline")
    }
    func testRecoversCommonMissingEndTagsAndDecodesEntities() throws {
        let article = try ArticleExtraction.parse(Data("<title>Test</title><main><p>One &lt; two<p>한글 &#x1F600;".utf8), source: "https://example.org")
        XCTAssertTrue(article.text.contains("One < two"))
        XCTAssertTrue(article.text.contains("한글 😀"))
    }
    func testRejectsInvalidEncodingEmptyAndOversizedPages() {
        for data in [Data([0xff]), Data("<html><body><script>only()</script></body></html>".utf8), Data(repeating: 65, count: ArticleExtraction.maximumBytes + 1)] {
            XCTAssertThrowsError(try ArticleExtraction.parse(data, source: "https://example.org"))
        }
        for source in ["http://example.org", "https://user:password@example.org", "file:///tmp/file", "javascript:alert(1)"] {
            XCTAssertThrowsError(try ArticleRecord.sourceURL(source))
        }
    }
    func testAtomicRecordStorageLinkOnlyAndExplicitRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root)
        var article = ArticleRecord(title: "Article", source: "https://example.org", text: "")
        try await store.save(article)
        article.text = "Available offline."
        try await store.save(article)
        let reloaded = try await ArticleStore(root: root).load(article.id)
        XCTAssertEqual(reloaded, article)
        var invalid = article; invalid.title = ""
        do { try await store.save(invalid); XCTFail("Must keep prior copy on invalid save") } catch {}
        let kept = try await store.load(article.id)
        XCTAssertEqual(kept, article)
        try await store.remove(article.id)
        let empty = try await store.summaries()
        XCTAssertTrue(empty.isEmpty)
    }
    func testLibrarySummariesDoNotRetainWholeArticleBodies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root)
        let record = ArticleRecord(title: "Long", source: "", text: String(repeating: "한글", count: 100_000))
        try await store.save(record)
        let summaries = try await store.summaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.preview.count, 240)
        let loaded = try await store.load(record.id)
        XCTAssertEqual(loaded.text, record.text)
    }

    func testArticleMetadataAndStableFilenameMatchReaderContract() async throws {
        let article = ArticleRecord(id: UUID(uuidString: "00000000-1111-2222-3333-444444444444")!, title: "한글 article",
                                    source: "https://example.org/read", text: "First paragraph.\n\nSecond.", savedAt: Date(timeIntervalSince1970: 1000))
        let metadata = try ArticleEPUB.metadata(article)
        XCTAssertEqual(metadata.count, 523)
        XCTAssertEqual(String(decoding: metadata.prefix(4), as: UTF8.self), "PDA1")
        XCTAssertEqual(Array(metadata[4..<12]), [232, 3, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(String(decoding: metadata[12..<269].prefix(while: { $0 != 0 }), as: UTF8.self), article.title)
        XCTAssertEqual(String(decoding: metadata[269..<523].prefix(while: { $0 != 0 }), as: UTF8.self), "example.org")
        let first = try await ArticleEPUB.write(article)
        let second = try await ArticleEPUB.write(article)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()); try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        XCTAssertEqual(first.lastPathComponent, "pd-article-00000000-1111-2222-3333-444444444444.epub")
        XCTAssertTrue(ArticleEPUB.isFilename(first.lastPathComponent))
        XCTAssertFalse(ArticleEPUB.isFilename("../" + first.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        let bytes = try Data(contentsOf: first)
        XCTAssertEqual(Array(bytes[58..<62]), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(String(decoding: bytes[88..<115], as: UTF8.self), "META-INF/pocket-article.bin")
        XCTAssertEqual(bytes[115..<638], metadata)
    }
}

private final class ArticlePageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let route = url.lastPathComponent
        let response = HTTPURLResponse(url: url, statusCode: route == "denied" ? 403 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": route == "image" ? "image/png" : "text/html",
                           "Content-Length": route == "large" ? "4194305" : "69"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html><title>Fixture</title><article><p>Local fixture text.</p></article></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
