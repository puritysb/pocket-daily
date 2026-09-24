import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Pocket

@MainActor
final class HostRendererBridgeTests: XCTestCase {
    private let options = HostRendererBridge.Options(sidePadding: 12, topPadding: 8, spacing: 4,
                                                     emptyTitle: "Pocket", emptyMessage: "No cards yet",
                                                     labels: ["Back", "", "Previous", "Next"])
    // Minimal deterministic cpfont v4 fixture, generated locally, not a bundled
    // production font. All printable ASCII glyphs have a2x2 black bitmap.
    private func font() -> Data {
        let count = 95, glyphStart = 76, bitmapStart = 76 + 95 * 16
        var bytes = Data(repeating: 0, count: bitmapStart + count)
        func put32(_ offset: Int, _ value: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        bytes.replaceSubrange(0..<6, with: "CPFONT".utf8)
        bytes[8] = 4
        bytes[12] = 1
        put32(36, 1)
        put32(40, count)
        bytes[44] = 12
        bytes[45] = 10
        put32(56, 64)
        put32(64, 32)
        put32(68, 126)
        for i in 0..<count {
            let start = glyphStart + i * 16
            bytes[start] = 2
            bytes[start + 1] = 2
            bytes[start + 2] = 48
            bytes[start + 8] = 1
            put32(start + 12, i)
            bytes[bitmapStart + i] = 0xC0
        }
        return bytes
    }

    func testBundledIdentityAndActualCardRenderingAcrossProfilesAndRotations() async throws {
        let accepted = try HostRendererBridge.Identity.accepted()
        XCTAssertEqual(accepted.abi, 1)
        XCTAssertEqual(accepted.sourceSHA256.count, 64)
        let card = ContentCard(id: "test", title: "Hello", question: "What next?", context: "Read one page.", imagePath: "image.pbm")
        let image = Data("P4\n8 1\n".utf8) + Data([0x81])
        for hardware in PocketHardware.allCases {
            for orientation in HostRendererBridge.Orientation.allCases {
                let renderer = try HostRendererBridge(font: font(), hardware: hardware, orientation: orientation)
                let frame = try await renderer.render(card: card, image: image, options: options)
                XCTAssertEqual(frame.pixels.count, hardware.screenWidth * hardware.screenHeight / 8)
                XCTAssertTrue(frame.pixels.contains(where: { $0 != 0xFF }))
                let cgImage = try XCTUnwrap(frame.image())
                XCTAssertEqual(cgImage.width, frame.width)
                XCTAssertEqual(cgImage.height, frame.height)
                let again = try await renderer.render(card: card, image: image, options: options)
                XCTAssertEqual(frame.pixels, again.pixels)
            }
        }
    }

    func testLayoutSelectionChangesActualPixelsAcrossProfilesAndRotations() async throws {
        var card = ContentCard(id: "layout", title: "오늘 한 장", question: "같은 콘텐츠, 다른 배치\nRead one page today.",
                               context: "텍스트와 이미지를 원하는 순서로 배치합니다.", imagePath: "image.pbm")
        let image = Data("P4\n64 64\n".utf8) + Data(repeating: 0xA5, count: 512)
        let previewFont = try await PreviewFontStore.shared.font()
        for hardware in PocketHardware.allCases {
            for orientation in HostRendererBridge.Orientation.allCases {
                let renderer = try HostRendererBridge(font: previewFont, hardware: hardware, orientation: orientation)
                var frames: [Data] = []
                for layout in ContentCard.Layout.allCases {
                    card.layout = layout
                    let frame = try await renderer.render(card: card, image: image, options: options)
                    XCTAssertFalse(frames.contains(frame.pixels), "Each layout must change actual pixels")
                    frames.append(frame.pixels)
                    #if canImport(UIKit)
                    if hardware == .x3 && orientation == .portrait {
                        let attachment = XCTAttachment(image: UIImage(cgImage: try XCTUnwrap(frame.image())))
                        attachment.name = "card-layout-\(layout.rawValue)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                    #endif
                }
                card.layout = .textFirst
                let restored = try await renderer.render(card: card, image: image, options: options)
                XCTAssertEqual(restored.pixels, frames[0])
            }
        }
    }

    func testInvalidImageThrowsAndExplicitRetryRecovers() async throws {
        let renderer = try HostRendererBridge(font: font(), hardware: .x3)
        let before = try await renderer.render(card: nil, options: options)
        let card = ContentCard(id: "test", title: "Hello", question: "Read", imagePath: "image.pbm")
        do {
            _ = try await renderer.render(card: card, image: Data([0]), options: options)
            XCTFail("Invalid PBM was rendered")
        } catch { XCTAssertEqual(error as? HostRendererBridge.Failure, .render(4)) }
        let after = try await renderer.render(card: nil, options: options)
        XCTAssertEqual(before.pixels, after.pixels)
    }

    func testMissingMetadataBadFontAndInvalidLabelsAreExplicitFailures() async throws {
        let unavailable = try HostRendererBridge(font: font(), hardware: .x3, bundle: Bundle(for: Self.self))
        do {
            _ = try await unavailable.render(card: nil, options: options)
            XCTFail("Missing metadata accepted")
        } catch { XCTAssertEqual(error as? HostRendererBridge.Failure, .unavailable) }
        let invalid = try HostRendererBridge(font: Data([0]), hardware: .x3)
        do {
            _ = try await invalid.render(card: nil, options: options)
            XCTFail("Invalid font accepted")
        } catch { XCTAssertEqual(error as? HostRendererBridge.Failure, .invalidFont) }
        let renderer = try HostRendererBridge(font: font(), hardware: .x3)
        var bad = options
        bad.labels = ["Back"]
        do {
            _ = try await renderer.render(card: nil, options: bad)
            XCTFail("Missing labels accepted")
        } catch { XCTAssertEqual(error as? HostRendererBridge.Failure, .invalidOptions) }
        bad = options
        bad.emptyTitle = String(repeating: "a", count: 64)
        do {
            _ = try await renderer.render(card: nil, options: bad)
            XCTFail("Unterminated text accepted")
        } catch { XCTAssertEqual(error as? HostRendererBridge.Failure, .invalidOptions) }
    }

    func testCancellationDoesNotReturnAPreview() async throws {
        let renderer = try HostRendererBridge(font: font(), hardware: .x3)
        let task = Task { try await renderer.render(card: nil, options: options) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled preview returned")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPhysicalBitsMapToLogicalPixelsInAllOrientations() throws {
        for orientation in HostRendererBridge.Orientation.allCases {
            let rotated = orientation == .portrait || orientation == .inverted
            let frame = HostRendererBridge.Frame(physicalWidth: 8, physicalHeight: 4,
                                                  width: rotated ? 4 : 8, height: rotated ? 8 : 4,
                                                  orientation: orientation, pixels: Data([0x7F, 0xFF, 0xFF, 0xFF]))
            let image = try XCTUnwrap(frame.image())
            let data = try XCTUnwrap(image.dataProvider?.data) as Data
            let expected: Int
            switch orientation {
            case .portrait: expected = 3
            case .clockwise: expected = 31
            case .inverted: expected = 28
            case .counterclockwise: expected = 0
            }
            XCTAssertEqual(data[expected], 0)
            XCTAssertEqual(data.filter { $0 == 0 }.count, 1)
        }
        let invalid = HostRendererBridge.Frame(physicalWidth: 8, physicalHeight: 4, width: 8, height: 4,
                                               orientation: .counterclockwise, pixels: Data())
        XCTAssertNil(invalid.image())
    }
}
