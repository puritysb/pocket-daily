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
        try await render(name: "03-card-x3", hardware: .x3, preview: .card, captureSheet: true)
        try await render(name: "04-sleep-x4", hardware: .x4, preview: .sleep)
        try await render(name: "06-device", hardware: .x3, section: .device)
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
        try await render(name: "dark-device", hardware: .x3, section: .device, dark: true)
    }

    /// QA captures of the states a first-time user meets outside demo mode and
    /// behind sheets: no reader yet, the reader's controls, the text panel, sync
    /// settings, adding an article, subscriptions, and About. Not store images.
    @MainActor
    func testRendersUserFlowStates() async throws {
        let model = PocketModel()
        try await renderView(ContentView(initialSection: .device).environmentObject(model),
                             name: "qa-device-no-reader", size: Self.pointSize)
        try await renderView(ContentView(initialSection: .device).environmentObject(model),
                             name: "qa-device-no-reader-dark", size: Self.pointSize, dark: true)
        try await renderView(ContentView(initialSection: .reader).environmentObject(model),
                             name: "qa-reader-overview", size: Self.pointSize)
        let demoReader = PocketModel()
        demoReader.enterDemoMode()
        try await renderView(ContentView(initialSection: .reader).environmentObject(demoReader),
                             name: "qa-reader-inventory-demo", size: Self.pointSize)
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

        let readingEditor = ProfileEditorState()
        try await renderView(ProfileStudioView(model: model, editor: readingEditor, initialPreview: .reading),
                             name: "qa-reading-portrait", size: Self.pointSize)
        readingEditor.reading.orientation = .landscape
        readingEditor.reading.lineSpacing = .wide
        readingEditor.reading.screenMargin = 30
        try await renderView(ProfileStudioView(model: model, editor: readingEditor, initialPreview: .reading),
                             name: "qa-reading-landscape", size: Self.pointSize)

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
        try await renderView(AppSettingsSheet(model: demo, appearance: .constant(.system)),
                             name: "qa-settings", size: NSSize(width: 520, height: 620))
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

    /// Extra IA QA captures stay in test attachments; the store manifest is unchanged.
    @MainActor
    func testRendersReaderTasksAndButtonMappings() async throws {
        let model = PocketModel()
        model.enterDemoMode()
        try await renderView(ContentView(initialSection: .reader).environmentObject(model),
                             name: "qa-my-reader-overview", size: Self.pointSize)
        for hardware in PocketHardware.allCases {
            model.preferredHardware = hardware
            let editor = ProfileEditorState()
            try await renderView(ProfileStudioView(model: model, editor: editor, initialPreview: .reading),
                                 name: "qa-buttons-\(hardware.rawValue)-portrait", size: Self.pointSize)
            try await renderView(ReaderButtonDiagram(hardware: hardware, preferences: editor.reading).padding(24),
                                 name: "qa-reading-button-diagram-\(hardware.rawValue)-portrait", size: NSSize(width: 420, height: 420))
            editor.reading.orientation = .landscape
            try await renderView(ReaderButtonDiagram(hardware: hardware, preferences: editor.reading).padding(24),
                                 name: "qa-reading-button-diagram-\(hardware.rawValue)-landscape", size: NSSize(width: 420, height: 420))
            try await renderView(ProfileStudioView(model: model, editor: editor, initialPreview: .reading),
                                 name: "qa-buttons-\(hardware.rawValue)-landscape", size: Self.pointSize)
        }
        let returnEditor = ProfileEditorState()
        var targetConsumed = false
        try await renderView(ProfileStudioView(model: model, editor: returnEditor,
                                                screenTaskRequest: .init(id: UUID(), screen: .brief),
                                                onScreenTaskOpened: { targetConsumed = true }),
                             name: "qa-owner-sleep-return", size: Self.pointSize)
        XCTAssertTrue(targetConsumed, "The owning screen request must be consumed after opening Sleep")
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let connected = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(),
                                    bookTransferStore: BookTransferJobStore(file: fixtureRoot.appendingPathComponent("jobs.json")))
        defer { connected.pauseForBackground() }
        connected.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"0.1.0","device":"X3","deviceID":"QA-INVENTORY","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"readerFiles":2,"readingProgress":1}"#.utf8))
        try await renderView(ReaderInventoryView(model: connected, library: .shared, open: { _ in }, connect: {}, manage: {}).padding(24),
                             name: "qa-reader-connected-inventory-not-checked", size: NSSize(width: 620, height: 620))
        connected.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"0.1.0","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        try await renderView(ReaderInventoryView(model: connected, library: .shared, open: { _ in }, connect: {}, manage: {}).padding(24),
                             name: "qa-reader-connected-inventory-unsupported", size: NSSize(width: 620, height: 440))
        await LibraryModel.shared.load()
        let book = try XCTUnwrap(LibraryModel.shared.books.first { $0.origin == .welcome })
        let created = await model.createBookTransferJob(books: [book], library: .shared)
        let id = try XCTUnwrap(created)
        try await renderView(BookTransferSheet(model: model, jobID: id, library: .shared,
                                               connection: { EmptyView() }, cancelConnection: {},
                                               onInventory: {}, onDevice: {}, onCurrentTask: {}),
                             name: "qa-selected-book-task-demo", size: NSSize(width: 560, height: 620))
        _ = await model.selectBookTransferDestination(id, destination: .sdCard)
        try await renderView(BookTransferSheet(model: model, jobID: id, library: .shared,
                                               connection: { EmptyView() }, cancelConnection: {},
                                               onInventory: {}, onDevice: {}, onCurrentTask: {}),
                             name: "qa-selected-book-sd-demo", size: NSSize(width: 560, height: 620))
        XCTAssertNil(model.bookTransferJob(id)?.latestSDCopy, "Demo destination selection must not start a directory operation")
        let content = try model.contentEditorModel()
        content.edit(ProfileStudioView.demoCards)
        try await renderView(StudioContentSheet(model: model, task: .cards, cards: content),
                             name: "qa-dedicated-cards", size: NSSize(width: 800, height: 680))
        try await renderView(StudioContentSheet(model: model, task: .glance),
                             name: "qa-dedicated-weather-calendar", size: NSSize(width: 540, height: 500))

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
    private func render(name: String, hardware: PocketHardware, section: StudioSection = .customize,
                        preview: ProfileStudioView.PreviewSurface = .home, shelf: LibraryView.Shelf = .books,
                        inbox: ArticleInboxModel? = nil, dark: Bool = false, captureSheet: Bool = false) async throws {
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

        let rep: NSBitmapImageRep
        if captureSheet {
            let deadline = Date().addingTimeInterval(10)
            while window.attachedSheet == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let sheet = try XCTUnwrap(window.attachedSheet, "The shipping My cards sheet was not presented")
            sheet.layoutIfNeeded()
            sheet.displayIfNeeded()
            // Native SwiftUI sheets own their title and toolbar in a separate
            // window. Capturing only the parent NSHostingView omits both.
            // Off-screen SwiftUI AX omits the navigation chrome. The real
            // title and Close are verified visually in the exported capture;
            // automated checks cover the attached sheet and native bitmap size.
            rep = try compositeWindowAndSheet(window, sheet: sheet, size: Self.pointSize)
            window.endSheet(sheet)
        } else {
            rep = try bitmap(of: window.contentView)
        }
        window.orderOut(nil)

        XCTAssertEqual(rep.pixelsWide, Int(Self.pointSize.width * 2), "unexpected backing scale for \(name)")
        XCTAssertEqual(rep.pixelsHigh, Int(Self.pointSize.height * 2), "unexpected backing scale for \(name)")

        let attachment = XCTAttachment(data: try opaquePNG(rep), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// In-process native view drawing needs neither screen recording nor UI
    /// automation. The real sheet chrome is included at its native size over
    /// the real source screen; no screenshot-only controls are authored.
    @MainActor
    private func compositeWindowAndSheet(_ window: NSWindow, sheet: NSWindow, size: NSSize) throws -> NSBitmapImageRep {
        let parent = try bitmap(of: window.contentView?.superview ?? window.contentView)
        let sheetView = try XCTUnwrap(sheet.contentView?.superview, "The native sheet frame view is unavailable")
        let child = try bitmap(of: sheetView)
        XCTAssertGreaterThan(child.pixelsWide, 0)
        XCTAssertGreaterThan(child.pixelsHigh, 0)
        XCTAssertEqual(CGFloat(child.pixelsWide), sheetView.bounds.width * sheet.backingScaleFactor, accuracy: 1)
        XCTAssertEqual(CGFloat(child.pixelsHigh), sheetView.bounds.height * sheet.backingScaleFactor, accuracy: 1)
        let scale = window.backingScaleFactor
        let result = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: result))
        var origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
        // AppKit can constrain the off-screen child to a physical display.
        // Restore only its normal attached position in the exported parent,
        // retaining the exact native frame/toolbar and content dimensions.
        if origin.x < 0 || origin.y < 0 || origin.x + sheetView.bounds.width > size.width || origin.y + sheetView.bounds.height > size.height {
            origin = NSPoint(x: (size.width - sheetView.bounds.width) / 2,
                             y: size.height - sheetView.bounds.height)
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        parent.draw(in: NSRect(origin: .zero, size: size))
        child.draw(in: NSRect(origin: origin, size: sheetView.bounds.size))
        return result
    }

    @MainActor
    private func bitmap(of view: NSView?) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(view, "The window view is unavailable")
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "The window could not create a bitmap")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
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
