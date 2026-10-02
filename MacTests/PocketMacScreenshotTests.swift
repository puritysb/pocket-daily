import AppKit
import SwiftUI
import XCTest

@testable import Pocket

/// Produces the Mac App Store screenshots from the shipping SwiftUI views.
///
/// This is a unit test, not a UI test, on purpose: the macOS UI-test runner needs the
/// Accessibility permission to enable automation mode, which cannot be granted from a
/// script or CI. Hosting the real view hierarchy in a real window and asking that window
/// to draw itself needs no permission at all, and unlike `ImageRenderer` it lays out the
/// scroll views the studio is built from.
final class PocketMacScreenshotTests: XCTestCase {
    /// 1440 × 900 points at the 2× backing scale is 2880 × 1800, an accepted Mac size.
    private static let pointSize = NSSize(width: 1440, height: 900)

    @MainActor
    func testRendersStoreScreenshots() async throws {
        try await render(name: "01-library", hardware: .x3, section: .library)
        try await render(name: "02-home-x3", hardware: .x3)
        try await render(name: "03-card-x3", hardware: .x3, preview: .card)
        try await render(name: "04-sleep-x4", hardware: .x4, preview: .sleep)
        try await render(name: "06-device", hardware: .x3, section: .reader)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("article-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ArticleFeedPreview.inbox(root: root)
        try await inbox.subscribe("https://journal.example/feed.xml")
        if let article = inbox.articles.first(where: { $0.title == "The books we return to" }) {
            await inbox.setArchived(article, true)
        }
        inbox.filter = .all
        try await render(name: "05-articles", hardware: .x3, section: .library, shelf: .articles, inbox: inbox)
    }

    @MainActor
    func testCoverFramesWithAndWithoutDailyPanel() async throws {
        let font = try await PreviewFontStore.shared.font()
        for hardware in PocketHardware.allCases {
            let renderer = try HostRendererBridge(font: font, hardware: hardware)
            for placement in [PocketProfile.WeatherPanel.top, .bottom, .off] {
                var profile = PocketProfile.defaults
                profile.home.weather = placement
                let frame = try await renderer.renderHome(profile: profile)
                let image = try XCTUnwrap(frame.image())
                let bitmap = NSBitmapImageRep(cgImage: image)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "qa-cover-\(hardware.rawValue)-\(placement.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testSleepWakeIndicatorPreviews() async throws {
        let font = try await PreviewFontStore.shared.font()
        for hardware in PocketHardware.allCases {
            let renderer = try HostRendererBridge(font: font, hardware: hardware)
            for enabled in [true, false] {
                let frame = try await renderer.renderBrief(profile: .defaults, wakeIndicator: enabled)
                let image = try XCTUnwrap(frame.image())
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "qa-wake-\(hardware.rawValue)-\(enabled ? "on" : "off")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// QA captures of the dark palette; not part of the store set (names carry no
    /// leading number, so the capture script skips them).
    @MainActor
    func testRendersDarkAppearance() async throws {
        try await render(name: "dark-library", hardware: .x3, section: .library, dark: true)
        try await render(name: "dark-home-x3", hardware: .x3, dark: true)
        try await render(name: "dark-device", hardware: .x3, section: .reader, dark: true)
    }

    /// QA captures of the states a first-time user meets outside demo mode and
    /// behind sheets: no reader yet, the reader's controls, the text panel, sync
    /// settings, adding an article, subscriptions, and About. Not store images.
    @MainActor
    func testRendersUserFlowStates() async throws {
        let model = PocketModel()
        try await renderView(ContentView(initialSection: .reader).environmentObject(model),
                             name: "qa-device-no-reader", size: Self.pointSize)
        try await renderView(ContentView(initialSection: .reader).environmentObject(model),
                             name: "qa-device-no-reader-dark", size: Self.pointSize, dark: true)
        try await renderView(ContentView(initialSection: .files).environmentObject(model),
                             name: "qa-files-no-reader", size: Self.pointSize)
        // Saved offline edits meeting a reader that changed in the meantime.
        let editor = ProfileEditorState()
        var mine = PocketProfile.defaults
        mine.home.weather = .top
        editor.restore(ProfileEditSnapshot(draft: mine, base: .defaults, baseGeneration: 1,
                                           reading: ReaderPreferences(), readingBase: ReaderPreferences(), savedAt: Date()))
        var onReader = PocketProfile.defaults
        onReader.home.weather = .off
        onReader.sleep.mode = .reader
        editor.sync(with: ReaderProfileState(deviceID: "1234ABCD", generation: 2, profile: onReader, maxHomeItems: 4))
        try await renderView(ProfileStudioView(model: model, editor: editor),
                             name: "qa-merge-notice", size: Self.pointSize)

        await LibraryModel.shared.load()
        let book = try XCTUnwrap(LibraryModel.shared.books.first { $0.origin == .welcome })
        let url = try await LibraryModel.shared.fileURL(for: book)
        let session = ReaderSession(bookFile: url, appearance: ReaderAppearance())
        session.open(at: nil)
        let reader = BookReaderView(book: book, session: session, library: .shared, sync: .shared, close: {})
        try await renderView(reader, name: "qa-reader-loading", size: NSSize(width: 1180, height: 780), settle: 0.3)
        let deadline = Date().addingTimeInterval(20)
        while session.phase != .ready, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        session.chromeVisible = true
        try await renderView(reader, name: "qa-reader-chrome", size: NSSize(width: 1180, height: 780))

        let demo = PocketModel()
        demo.enterDemoMode()
        try await renderView(ReaderAppearancePanel(store: ReaderAppearanceStore.shared),
                             name: "qa-reader-appearance", size: NSSize(width: 420, height: 520))
        try await renderView(AppSettingsWindow().environmentObject(demo),
                             name: "qa-settings-window", size: NSSize(width: 520, height: 480))
        try await renderView(AppSettingsSheet(model: demo),
                             name: "qa-settings", size: NSSize(width: 520, height: 720))
        try await renderView(ReaderBluetoothPairingCard(sync: .shared).padding(20),
                             name: "qa-bluetooth-pairing", size: NSSize(width: 360, height: 300))
        try await renderView(ArticleCaptureView(initialURL: "", completed: {}),
                             name: "qa-article-add", size: NSSize(width: 520, height: 620))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-feeds-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ArticleFeedPreview.inbox(root: root)
        try await inbox.subscribe("https://journal.example/feed.xml")
        try await renderView(ArticleSubscriptionsView(inbox: inbox, isDemo: true),
                             name: "qa-subscriptions", size: NSSize(width: 520, height: 520))
        try await renderView(ProjectInformationSheet(), name: "qa-about", size: NSSize(width: 560, height: 700))
    }

    /// Hosts any view in a key off-screen window and attaches its drawing.
    @MainActor
    private func renderView(_ view: some View, name: String, size: NSSize, dark: Bool = false,
                            settle: TimeInterval = 3) async throws {
        let content = view.preferredColorScheme(dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let frame = NSRect(origin: NSPoint(x: 0, y: -20_000), size: size)
        let window = CaptureWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .seconds(settle))
        window.displayIfNeeded()
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            XCTFail("Could not create a bitmap for \(name)")
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        window.orderOut(nil)
        let attachment = XCTAttachment(data: try opaquePNG(rep), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRendersFirmwareUpdateCard() async throws {
        let release = FirmwareRelease(version: "1.8.0", downloadURL: URL(string: "https://example.invalid/firmware.bin")!,
                                      byteCount: 1, publishedAt: ISO8601DateFormatter().date(from: "2026-09-26T08:00:00Z"))
        let model = PocketModel(releaseSource: .init(latest: { release }))
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.7.0","device":"X3","deviceID":"QA-CARD","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        await model.checkFirmwareAtLaunch()
        XCTAssertTrue(model.firmwareUpdateAvailable)
        XCTAssertTrue(model.canUpdateReader)
        try await renderCard(FirmwareUpdateCard(model: model, isUpdating: false, update: {}, cancel: {}),
                             name: "firmware-update-available", height: 230)
        // Development builds add the local-build action under the official one.
        XCTAssertTrue(model.canSendLocalFirmware)
        try await renderCard(FirmwareUpdateCard(model: model, isUpdating: false, update: {}, cancel: {},
                                                sendLocalBuild: {}),
                             name: "firmware-local-build", height: 330)
    }

    @MainActor
    private func renderCard(_ card: some View, name: String, height: CGFloat) async throws {
        let content = card.padding(16).frame(width: 360, height: height).background(PocketPalette.workspace)
            .preferredColorScheme(.light)
        let hosting = NSHostingView(rootView: content)
        let frame = NSRect(x: 0, y: -20_000, width: 360, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let attachment = XCTAttachment(data: try opaquePNG(rep), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func render(name: String, hardware: PocketHardware, section: StudioSection = .layout,
                        preview: ProfileStudioView.PreviewSurface = .home, shelf: LibraryView.Shelf = .books,
                        inbox: ArticleInboxModel? = nil, dark: Bool = false) async throws {
        let savedAppearance = UserDefaults.standard.object(forKey: "appAppearance")
        UserDefaults.standard.set(dark ? "dark" : "light", forKey: "appAppearance")
        defer {
            if let savedAppearance { UserDefaults.standard.set(savedAppearance, forKey: "appAppearance") }
            else { UserDefaults.standard.removeObject(forKey: "appAppearance") }
        }
        let model = PocketModel()
        model.preferredHardware = hardware
        model.enterDemoMode()

        let content = ContentView(initialSection: section, initialPreview: preview, initialShelf: shelf, inbox: inbox)
            .environmentObject(model)
            .preferredColorScheme(dark ? .dark : .light)
            // The test runner is never the frontmost app, so AppKit would draw every
            // control dimmed; tell SwiftUI the window is active regardless.
            .environment(\.controlActiveState, .key)

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: Self.pointSize)

        // Borderless and positioned off-screen: AppKit clamps a titled window to the
        // screen's visible frame, which silently cropped the capture to the display
        // height instead of the requested 900 points.
        let frame = NSRect(origin: NSPoint(x: 0, y: -20_000), size: Self.pointSize)
        let window = CaptureWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setFrame(frame, display: true)
        // Order the window in so AppKit gives it a backing store and SwiftUI performs a
        // real layout pass; an unrealised window never lays out its scroll view contents.
        // It must also be the key window: controls in an inactive window draw in the
        // dimmed "background" style, which turned every toggle and bar grey.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // Yield the main actor so SwiftUI tasks can publish their rendered frames.
        // Spinning RunLoop here blocks actor work and captures the initial outline.
        try await Task.sleep(for: .seconds(4))
        window.displayIfNeeded()

        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not create a bitmap for \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)

        XCTAssertEqual(rep.pixelsWide, Int(Self.pointSize.width * 2), "unexpected backing scale for \(name)")
        XCTAssertEqual(rep.pixelsHigh, Int(Self.pointSize.height * 2), "unexpected backing scale for \(name)")

        let attachment = XCTAttachment(data: try opaquePNG(rep), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// App Store Connect rejects screenshots that carry an alpha channel, so compose the
    /// capture onto opaque white before encoding.
    private func opaquePNG(_ rep: NSBitmapImageRep) throws -> Data {
        guard let source = rep.cgImage else { throw XCTSkip("No CGImage in the captured bitmap") }
        guard let context = CGContext(
            data: nil,
            width: source.width,
            height: source.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw XCTSkip("Could not create a bitmap context")
        }
        let frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(frame)
        context.draw(source, in: frame)

        guard let flattened = context.makeImage(),
              let opaque = NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:]) else {
            throw XCTSkip("Could not encode the flattened PNG")
        }
        return opaque
    }
}

/// A borderless window that can become key, so captured controls draw in their
/// active appearance.
private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
