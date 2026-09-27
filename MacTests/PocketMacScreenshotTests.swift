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
    func testRendersStoreScreenshots() throws {
        try render(name: "01-home-x3", hardware: .x3)
        try render(name: "02-card-x3", hardware: .x3, preview: .card)
        try render(name: "03-sleep-x4", hardware: .x4, preview: .sleep)
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
        let content = FirmwareUpdateCard(model: model, isUpdating: false, update: {}, cancel: {})
            .padding(16).frame(width: 360, height: 230).background(PocketPalette.workspace)
            .preferredColorScheme(.light)
        let hosting = NSHostingView(rootView: content)
        let frame = NSRect(x: 0, y: -20_000, width: 360, height: 230)
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
        attachment.name = "firmware-update-available"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func render(name: String, hardware: PocketHardware,
                        preview: ProfileStudioView.PreviewSurface = .home) throws {
        let model = PocketModel()
        model.preferredHardware = hardware
        model.enterDemoMode()

        let content = ContentView(initialPreview: preview)
            .environmentObject(model)
            .preferredColorScheme(.light)

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: Self.pointSize)

        // Borderless and positioned off-screen: AppKit clamps a titled window to the
        // screen's visible frame, which silently cropped the capture to the display
        // height instead of the requested 900 points.
        let frame = NSRect(origin: NSPoint(x: 0, y: -20_000), size: Self.pointSize)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrame(frame, display: true)
        // Order the window in so AppKit gives it a backing store and SwiftUI performs a
        // real layout pass; an unrealised window never lays out its scroll view contents.
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // Let SwiftUI settle: the studio measures itself with GeometryReader, so its
        // contents appear one layout pass after the window is sized.
        // The canvases render the reader frame off the main actor (font load and
        // native drawing), so give them time to replace the outline.
        RunLoop.current.run(until: Date().addingTimeInterval(4.0))
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
