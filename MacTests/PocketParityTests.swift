import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Pocket

/// Hardware parity evidence (sibling docs/pocket-profile-v1.md, P1-1): the host
/// render of a card with the reader's own resolved inputs must equal the frame
/// the reader drew. Runs only when TEST_RUNNER_POCKET_PARITY_DIR points at:
///   display.json  GET /api/pocket/v1/display
///   state.json    GET /api/pocket/v1/content/state (active revision)
///   cards.json    the studio's exported cards (Export cards…)
///   device.bmp    POST dev/capture + GET dev/frame after a rendered receipt
/// It writes host.png and diff.png next to them.
final class PocketParityTests: XCTestCase {
    func testHostRenderMatchesTheCapturedReaderFrame() async throws {
        guard let path = ProcessInfo.processInfo.environment["POCKET_PARITY_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POCKET_PARITY_DIR to run the hardware parity check")
        }
        let dir = URL(fileURLWithPath: path)
        let displayData = try Data(contentsOf: dir.appendingPathComponent("display.json"))
        let deviceID = try XCTUnwrap((try JSONSerialization.jsonObject(with: displayData) as? [String: Any])?["deviceID"] as? String)
        let display = try ReaderDisplayState.decode(displayData, deviceID: deviceID)
        let draft = try ContentDraftFile.decode(Data(contentsOf: dir.appendingPathComponent("cards.json")))

        // Same content bytes as the reader's active revision, not a look-alike.
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("state.json"))) as? [String: Any]
        let active = try XCTUnwrap((state?["active"] as? [String: Any])?["revision"] as? String)
        XCTAssertEqual(try draft.revision().revision, active, "Exported cards must be the reader's active revision")

        let index = Int(ProcessInfo.processInfo.environment["POCKET_PARITY_CARD"] ?? "0") ?? 0
        let card = try XCTUnwrap(draft.cards.indices.contains(index) ? draft.cards[index] : nil)
        let device = try gray(XCTUnwrap(loadImage(dir.appendingPathComponent("device.bmp"))))
        let hardware: PocketHardware = device.width == PocketHardware.x3.screenWidth ? .x3 : .x4

        XCTAssertTrue(display.matchesPreviewFont, "Reader font size \(display.fontPointSize) differs from the bundled preview font")
        let renderer = try HostRendererBridge(font: try await PreviewFontStore.shared.font(), hardware: hardware,
                                              orientation: display.orientation)
        let frame = try await renderer.render(card: card, image: draft.images[card.imagePath],
                                              options: PreviewStyle(reader: display).options)
        let host = try gray(XCTUnwrap(frame.image()))
        XCTAssertEqual(host.width, device.width)
        XCTAssertEqual(host.height, device.height)

        var differing = 0
        var diff = [UInt8](repeating: 255, count: host.width * host.height * 4)
        for i in 0..<min(host.pixels.count, device.pixels.count) {
            let hostInk = host.pixels[i] < 128
            let deviceInk = device.pixels[i] < 128
            let o = i * 4
            if hostInk != deviceInk {
                differing += 1
                (diff[o], diff[o + 1], diff[o + 2]) = hostInk ? (0, 0, 255) : (255, 0, 0)  // blue host-only, red device-only
            } else if hostInk {
                (diff[o], diff[o + 1], diff[o + 2]) = (0, 0, 0)
            }
        }
        try writePNG(host.pixels, width: host.width, height: host.height, gray: true, to: dir.appendingPathComponent("host.png"))
        try writePNG(diff, width: host.width, height: host.height, gray: false, to: dir.appendingPathComponent("diff.png"))
        print("PARITY differing=\(differing) of \(host.width * host.height) theme=\(display.theme)")
        XCTAssertEqual(differing, 0, "Host preview differs from the reader frame in \(differing) pixels; see diff.png")
    }

    private struct Gray { let width: Int; let height: Int; let pixels: [UInt8] }

    private func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func gray(_ image: CGImage) throws -> Gray {
        var pixels = [UInt8](repeating: 255, count: image.width * image.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw CocoaError(.fileReadCorruptFile) }
        return Gray(width: image.width, height: image.height, pixels: pixels)
    }

    private func writePNG(_ bytes: [UInt8], width: Int, height: Int, gray: Bool, to url: URL) throws {
        let components = gray ? 1 : 4
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components,
                                  bytesPerRow: width * components,
                                  space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: gray ? CGImageAlphaInfo.none.rawValue
                                                                         : CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
