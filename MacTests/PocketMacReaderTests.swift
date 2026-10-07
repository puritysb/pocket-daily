import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import Pocket

/// The Mac reader, driven without UI automation: the guide book opens in the
/// shipping reader view inside an off-screen window, turns a page from the
/// keyboard path, and draws text.
final class PocketMacReaderTests: XCTestCase {
    @MainActor
    func testGuideBookRendersAndTurnsPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacReader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookLibrary(root: root)
        let book = try await storage.importDocument(WelcomeBook.document, origin: .welcome)
        let url = try await storage.fileURL(for: book)

        let session = ReaderSession(bookFile: url, appearance: ReaderAppearance())
        session.open(at: nil)
        let hosting = NSHostingView(rootView: ReaderWebView(session: session).frame(width: 720, height: 900))
        let frame = NSRect(x: 0, y: -20_000, width: 720, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        try await waitUntil("the first page") { session.phase == .ready && session.position != nil }
        XCTAssertFalse(session.toc.isEmpty, "Contents were not read")
        let first = try XCTUnwrap(session.position)
        XCTAssertEqual(first.fraction, 0, accuracy: 0.001)
        XCTAssertEqual(first.xpointer?.hasPrefix("/body/DocFragment[1]/body"), true)

        let text = try await session.webView.evaluateJavaScript("document.querySelector('foliate-view') != null") as? Bool
        XCTAssertEqual(text, true)
        // Relocation proves pagination, but the off-screen WebKit compositor
        // can paint afterward. Wait for the actual pixels under test.
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let paintDeadline = ContinuousClock.now + .seconds(5)
        hosting.layoutSubtreeIfNeeded()
        session.webView.layoutSubtreeIfNeeded()
        var image = try await session.webView.takeSnapshot(configuration: configuration)
        while !Self.hasInk(image), ContinuousClock.now < paintDeadline {
            try await Task.sleep(for: .milliseconds(100))
            guard ContinuousClock.now < paintDeadline else { break }
            hosting.layoutSubtreeIfNeeded()
            session.webView.layoutSubtreeIfNeeded()
            image = try await session.webView.takeSnapshot(configuration: configuration)
        }
        attach(image, "mac-reader-first-page")
        XCTAssertTrue(Self.hasInk(image),
                      "The page drew no text within 5 seconds; WebView bounds \(session.webView.bounds), host bounds \(hosting.bounds), window visible \(window.isVisible), phase \(session.phase)")

        // Empty page space belongs to the host document, outside the book iframe.
        _ = try await session.webView.evaluateJavaScript("document.dispatchEvent(new MouseEvent('click', { clientX: innerWidth / 2, bubbles: true }))")
        try await waitUntil("controls from a margin tap") { session.chromeVisible }
        _ = try await session.webView.evaluateJavaScript("document.dispatchEvent(new MouseEvent('click', { clientX: innerWidth / 2, bubbles: true }))")
        try await waitUntil("controls hidden by a second margin tap") { !session.chromeVisible }

        session.next()
        try await waitUntil("a page turn") { (session.position?.fraction ?? 0) > first.fraction }
        let turned = try XCTUnwrap(session.position)
        // Immediately after a turn, like tapping Go on an offer right away.
        session.go(to: first)
        try await waitUntil("the jump back (turned \(turned.fraction), now \(session.position?.fraction ?? -1), \(session.position?.xpointer ?? "nil"))") {
            abs((session.position?.fraction ?? 1) - first.fraction) < 0.001
        }
    }

    /// Reading is part of the root window, and Escape returns to its retained Library.
    @MainActor
    func testReadingReturnsToLibraryInTheSameWindow() async throws {
        await LibraryModel.shared.load()
        let book = try XCTUnwrap(LibraryModel.shared.books.first { $0.origin == .welcome })
        let model = PocketModel()
        model.enterDemoMode()
        let hosting = NSHostingView(rootView: ContentView(initialBookID: book.id).environmentObject(model))
        let frame = NSRect(x: 0, y: -20_000, width: 1180, height: 780)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func reader(in view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap { reader(in: $0) }.first
        }
        try await waitUntil("the embedded reader") { reader(in: hosting) != nil }
        let webView = try XCTUnwrap(reader(in: hosting))
        XCTAssertTrue(webView.window === window)
        let deadline = Date().addingTimeInterval(20)
        var ready = false
        while Date() < deadline && !ready {
            ready = (try? await webView.evaluateJavaScript("document.querySelector('foliate-view')?.renderer != null")) as? Bool == true
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(ready, "The embedded book did not render")
        // Exercise the shipping keyboard handler, which calls the root's back action.
        _ = try await webView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))")
        try await waitUntil("return to the Library") { reader(in: hosting) == nil }
        XCTAssertTrue(hosting.window === window)
        XCTAssertTrue(window.isVisible, "Returning from reading must keep the app window open")
    }

    /// Real-world books, when `TEST_RUNNER_POCKET_EPUB_SAMPLES` names a folder of
    /// EPUB files: import, render, turn, jump to the middle, and restore that
    /// place from its XPointer alone in a fresh reader, as another device would.
    @MainActor
    func testSampleBooksImportRenderAndRestore() async throws {
        guard let folder = ProcessInfo.processInfo.environment["POCKET_EPUB_SAMPLES"] else {
            throw XCTSkip("Set TEST_RUNNER_POCKET_EPUB_SAMPLES to a folder of EPUB files.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSamples-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookLibrary(root: root)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "epub" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let started = Date()
            let book = try await storage.importFile(at: file)
            XCTAssertFalse(book.title.isEmpty, name)
            let url = try await storage.fileURL(for: book)
            let (session, window) = open(url)
            try await waitUntil("\(name) first page", timeout: 60) { session.phase == .ready && session.position != nil }
            let opened = Date().timeIntervalSince(started)
            let start = try XCTUnwrap(session.position)
            for _ in 0..<3 { session.next(); try await Task.sleep(for: .milliseconds(250)) }
            try await waitUntil("\(name) turns") { (session.position?.fraction ?? 0) > start.fraction }
            session.go(toFraction: 0.5)
            try await waitUntil("\(name) middle", timeout: 30) { abs((session.position?.fraction ?? 0) - 0.5) < 0.05 }
            try await Task.sleep(for: .milliseconds(400))
            let middle = try XCTUnwrap(session.position)
            let xpointer = try XCTUnwrap(middle.xpointer, "\(name) has no XPointer at the middle")
            let image = try await session.webView.takeSnapshot(configuration: nil)
            attach(image, "sample-\(name)-middle")
            XCTAssertTrue(Self.hasInk(image), "\(name) drew no text")
            window.orderOut(nil)

            let (restored, restoredWindow) = open(url, at: ReadingPosition(fraction: 0, xpointer: xpointer, cfi: nil,
                                                                           chapter: nil, updatedAt: Date()))
            try await waitUntil("\(name) restore", timeout: 60) { restored.phase == .ready && restored.position != nil }
            try await Task.sleep(for: .milliseconds(400))
            let landed = try XCTUnwrap(restored.position)
            XCTAssertEqual(landed.fraction, middle.fraction, accuracy: 0.02,
                           "\(name): \(xpointer) restored to \(landed.xpointer ?? "nil")")
            print("sample \(name): opened in \(String(format: "%.1f", opened)) s, toc \(session.toc.count), middle \(xpointer), restored \(landed.xpointer ?? "nil")")
            restoredWindow.orderOut(nil)
        }
    }

    /// Firmware-generated XPointers (sibling test/reading_progress/fixtures) must
    /// resolve in the app's XPointer module to the same text the firmware saw.
    @MainActor
    func testFirmwareXPointersResolveToTheSameText() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("pocket-daily-firmware/test/reading_progress/fixtures")
        let golden = fixtures.appendingPathComponent("firmware-xpointers.json")
        guard FileManager.default.fileExists(atPath: golden.path) else {
            throw XCTSkip("The sibling firmware checkout with reading-progress fixtures is not present.")
        }
        struct Position: Decodable { let sectionIndex: Int; let xpointer: String; let textAt: String }
        struct Book: Decodable { let epub: String; let positions: [Position] }
        struct Golden: Decodable { let books: [Book] }
        let books = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: golden)).books

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(ReaderSchemeHandler(bookFile: golden), forURLScheme: ReaderSchemeHandler.scheme)
            return configuration
        }())
        let loaded = expectation(description: "loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<!doctype html><title>x</title>", baseURL: URL(string: "pocket-reader://engine/"))
        await fulfillment(of: [loaded], timeout: 10)

        var total = 0
        var mismatches: [String] = []
        for book in books {
            let archive = try ZIPArchive(url: fixtures.appendingPathComponent(book.epub))
            let sections = try Self.spine(archive)
            for position in book.positions {
                total += 1
                let path = sections[position.sectionIndex]
                let xhtml = String(decoding: try archive.data(for: XCTUnwrap(archive.entry(path)), limit: 8 << 20), as: UTF8.self)
                let text = try await webView.callAsyncJavaScript("""
                    const X = await import('pocket-reader://engine/xpointer.js')
                    const doc = new DOMParser().parseFromString(xhtml, 'application/xhtml+xml')
                    const parsed = X.parse(xpointer)
                    if (!parsed) return 'unparsed'
                    const { range } = X.toRange(doc, parsed)
                    let node = range.startContainer, offset = range.startOffset, out = ''
                    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
                    if (node.nodeType !== Node.TEXT_NODE) {
                        const marker = node.childNodes[offset] ?? node
                        walker.currentNode = marker
                        node = marker.nodeType === Node.TEXT_NODE ? marker : walker.nextNode()
                        offset = 0
                    } else walker.currentNode = node
                    while (node && [...out].length < 12) {
                        out += node.data.slice(offset)
                        offset = 0
                        node = walker.nextNode()
                    }
                    return [...out].slice(0, 12).join('')
                    """, arguments: ["xhtml": xhtml, "xpointer": position.xpointer], contentWorld: .page) as? String
                if text != position.textAt {
                    mismatches.append("\(book.epub) \(position.xpointer): firmware \"\(position.textAt)\" app \"\(text ?? "nil")\"")
                }
            }
        }
        print("firmware XPointers: \(total - mismatches.count)/\(total) resolve to the same text")
        XCTAssertGreaterThan(total, 200)
        XCTAssertTrue(mismatches.isEmpty, mismatches.prefix(10).joined(separator: "\n")); mismatches.forEach { print("MISMATCH", $0) }
        _ = delegate
    }

    private static func spine(_ archive: ZIPArchive) throws -> [String] {
        let container = String(decoding: try archive.data(for: XCTUnwrap(archive.entry("META-INF/container.xml")), limit: 1 << 20), as: UTF8.self)
        let opfPath = try XCTUnwrap(container.firstMatch(of: /full-path="([^"]+)"/)).1
        let opf = String(decoding: try archive.data(for: XCTUnwrap(archive.entry(String(opfPath))), limit: 4 << 20), as: UTF8.self)
        var hrefs: [String: String] = [:]
        for item in opf.matches(of: /<item\b[^>]*>/) {
            let tag = String(item.0)
            if let id = tag.firstMatch(of: /\bid="([^"]+)"/)?.1, let href = tag.firstMatch(of: /\bhref="([^"]+)"/)?.1 {
                hrefs[String(id)] = EPUBPackageReader.resolve(String(href), relativeTo: String(opfPath))
            }
        }
        return opf.matches(of: /<itemref\b[^>]*idref="([^"]+)"/).compactMap { hrefs[String($0.1)] }
    }

    @MainActor
    private func open(_ url: URL, at position: ReadingPosition? = nil) -> (ReaderSession, NSWindow) {
        let session = ReaderSession(bookFile: url, appearance: ReaderAppearance())
        session.open(at: position)
        let hosting = NSHostingView(rootView: ReaderWebView(session: session).frame(width: 720, height: 900))
        let frame = NSRect(x: 0, y: -20_000, width: 720, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return (session, window)
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// True when the snapshot has dark text pixels on the light page.
    private static func hasInk(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        var dark = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                if let color = rep.colorAt(x: x, y: y), color.brightnessComponent < 0.35 { dark += 1 }
            }
        }
        return dark > 200
    }

    private func attach(_ image: NSImage, _ name: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
