import WebKit
import XCTest
@testable import Pocket

/// The bundled engine: the scheme handler serves only engine files and the open
/// book, and the XPointer module matches KOReader's serialization in WebKit.
@MainActor
final class ReaderEngineTests: XCTestCase {
    private let handler = ReaderSchemeHandler(bookFile: URL(fileURLWithPath: "/dev/null"))

    func testSchemeHandlerServesOnlyEngineFiles() {
        XCTAssertNotNil(handler.resolve("/reader.html"))
        XCTAssertNotNil(handler.resolve("/foliate-js/view.js"))
        XCTAssertNotNil(handler.resolve("/xpointer.js"))
        XCTAssertNil(handler.resolve("/../Info.plist"))
        XCTAssertNil(handler.resolve("/foliate-js"), "Directories are not served")
        XCTAssertNil(handler.resolve("/missing.js"))
        XCTAssertNil(handler.resolve("/"))
        XCTAssertEqual(ReaderSchemeHandler.contentType("js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(ReaderSchemeHandler.contentType("epub"), "application/epub+zip")
    }

    func testEngineSourceIsPinned() throws {
        let root = try XCTUnwrap(Bundle.main.url(forResource: "ReaderEngine", withExtension: nil))
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("SOURCE.json"))) as? [String: Any]
        XCTAssertEqual((source?["commit"] as? String)?.count, 40)
        for file in source?["files"] as? [String] ?? [] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("foliate-js/\(file)").path), file)
        }
    }

    func testXPointerMatchesKOReaderSerialization() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(handler, forURLScheme: ReaderSchemeHandler.scheme)
            return configuration
        }())
        let loaded = expectation(description: "loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<!doctype html><title>t</title>", baseURL: URL(string: "pocket-reader://engine/"))
        await fulfillment(of: [loaded], timeout: 10)

        let script = """
        const X = await import('pocket-reader://engine/xpointer.js')
        const html = `<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body>
          <h1>Title</h1>
          <div><p>First 👩🏽‍💻 para</p>
          <p>Second <b>bold</b> tail text</p></div>
          <p>Only</p>
        </body></html>`
        const doc = new DOMParser().parseFromString(html, 'application/xhtml+xml')
        const ps = doc.querySelectorAll('p')
        const at = (node, offset) => { const r = doc.createRange(); r.setStart(node, offset); return r }
        const out = {}
        out.emoji = X.fromRange(doc, at(ps[0].firstChild, 'First 👩🏽‍💻 '.length), 2)
        out.second = X.fromRange(doc, at(ps[1].lastChild, 3), 0)
        out.bodyStart = X.fromRange(doc, at(doc.body, 0), 0)
        out.only = X.fromRange(doc, at(ps[2].firstChild, 2), 4)
        const back = X.toRange(doc, X.parse(out.emoji))
        out.roundTrip = back.exact && back.range.startContainer === ps[0].firstChild
            && back.range.startOffset === 'First 👩🏽‍💻 '.length
        const explicit = X.toRange(doc, X.parse('/body/DocFragment[3]/body/div[1]/p[2]/text()[2].3'))
        out.explicit = explicit.exact && explicit.range.startContainer === ps[1].lastChild
        out.fallback = X.toRange(doc, X.parse('/body/DocFragment[1]/body/div/p[9]/text().4')).range.startContainer.localName
        out.invalid = [X.parse('garbage'), X.parse('/body/DocFragment[0]/body')].every(v => v === null)
        return JSON.stringify(out)
        """
        let json = try await webView.callAsyncJavaScript(script, contentWorld: .page) as? String
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(json).utf8)) as? [String: Any])
        XCTAssertEqual(result["emoji"] as? String, "/body/DocFragment[3]/body/div/p[1]/text().11",
                       "Offsets count code points, not UTF-16 units")
        XCTAssertEqual(result["second"] as? String, "/body/DocFragment[1]/body/div/p[2]/text()[2].3")
        XCTAssertEqual(result["bodyStart"] as? String, "/body/DocFragment[1]/body/h1/text().0")
        XCTAssertEqual(result["only"] as? String, "/body/DocFragment[5]/body/p/text().2")
        XCTAssertEqual(result["roundTrip"] as? Bool, true)
        XCTAssertEqual(result["explicit"] as? Bool, true)
        XCTAssertEqual(result["fallback"] as? String, "div")
        XCTAssertEqual(result["invalid"] as? Bool, true)
        _ = delegate
    }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
