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
        let image = try await session.webView.takeSnapshot(configuration: nil)
        attach(image, "mac-reader-first-page")
        XCTAssertTrue(Self.hasInk(image), "The page drew no text")

        session.next()
        try await waitUntil("a page turn") { (session.position?.fraction ?? 0) > first.fraction }
        let turned = try XCTUnwrap(session.position)
        // Immediately after a turn, like tapping Go on an offer right away.
        session.go(to: first)
        try await waitUntil("the jump back (turned \(turned.fraction), now \(session.position?.fraction ?? -1), \(session.position?.xpointer ?? "nil"))") {
            abs((session.position?.fraction ?? 1) - first.fraction) < 0.001
        }
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
