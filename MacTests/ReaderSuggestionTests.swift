import AppKit
import SwiftUI
import XCTest
@testable import Pocket

@MainActor
final class ReaderSuggestionTests: XCTestCase {
    func testVisibleSuggestionAcceptsThroughItsButton() async throws {
        try await acceptsSuggestion(width: 620)
    }

    func testNarrowSuggestionWithLongReaderNameKeepsAcceptanceVisible() async throws {
        try await acceptsSuggestion(width: 320)
    }

    private func acceptsSuggestion(width: CGFloat) async throws {
        let domain = "ReaderSuggestion." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "library.welcome.v1")
        defaults.set(false, forKey: "sync.icloud.enabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let storage = BookLibrary(root: root)
        let book = try await storage.importDocument(WelcomeBook.document, origin: .written)
        let library = LibraryModel(storage: storage, defaults: defaults)
        await library.load()
        let sync = ReadingSync(defaults: defaults, iCloudAvailable: { false })
        let session = ReaderSession(bookFile: try await library.fileURL(for: book), appearance: ReaderAppearance())
        session.open(at: nil)
        let hosting = NSHostingView(rootView: BookReaderView(book: book, session: session, library: library, sync: sync, close: {}))
        let frame = NSRect(x: 0, y: -20_000, width: width, height: 850)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.setFrame(frame, display: true); window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func wait(_ ready: () -> Bool) async throws {
            let end = Date().addingTimeInterval(20)
            while !ready() && Date() < end { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(ready())
        }
        try await wait { session.phase == .ready && session.position != nil }
        session.go(toFraction: 0.65)
        try await wait { (session.position?.fraction ?? 0) > 0.2 }
        let remote = try XCTUnwrap(session.position)
        session.go(toFraction: 0)
        try await wait { (session.position?.fraction ?? 1) < 0.01 }
        let list = ReaderReadingList(v: 1, deviceID: "12345678", books: [.init(path: nil, document: book.documentDigest,
            progress: remote.xpointer, percentage: remote.fraction, updated: Int(Date().timeIntervalSince1970) + 10, seq: 1)], offerVersion: 2)
        let readerName = width < 400 ? "My reader with a longer descriptive name" : "Test reader"
        _ = sync.exchange(with: list, readerName: readerName, library: library.books)
        sync.exchangeFinished(readerName: readerName, sent: 0, error: nil)
        let suggestion = await sync.suggestion(for: book, current: library.book(book.id)?.position)
        XCTAssertNotNil(suggestion)
        try await Task.sleep(for: .seconds(1))
        let label = "Go to " + remote.fraction.formatted(.percent.precision(.fractionLength(0)))
        let button = try await ReaderContinuityInput.locate(label, in: hosting)
        XCTAssertLessThan(session.position?.fraction ?? 1, 0.01, "The suggestion must not navigate before consent")
        try ReaderContinuityInput.press(button, in: window, name: "suggestion-banner")
        try await wait { (session.position?.fraction ?? 0) > 0.2 }
    }
}
