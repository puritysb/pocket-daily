import XCTest
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import Pocket

@MainActor
final class ContentPreviewModelTests: XCTestCase {
    private actor Gate {
        var pending: [String: CheckedContinuation<CGImage, Error>] = [:]
        func render(_ request: ContentPreviewRequest) async throws -> CGImage {
            try await withCheckedThrowingContinuation { pending[request.card?.id ?? "empty"] = $0 }
        }
        func has(_ key: String) -> Bool { pending[key] != nil }
        func finish(_ key: String, image: CGImage) { pending.removeValue(forKey: key)?.resume(returning: image) }
    }
    private func request(_ id: String) -> ContentPreviewRequest {
        .init(card: .init(id: id, title: "Card", question: "Read"), image: nil, hardware: .x3, orientation: .portrait)
    }
    private func image(_ byte: UInt8) throws -> CGImage {
        try XCTUnwrap(HostRendererBridge.Frame(physicalWidth: 8, physicalHeight: 1, width: 8, height: 1,
                       orientation: .counterclockwise, pixels: Data([byte])).image())
    }
    private func wait(_ key: String, gate: Gate) async throws {
        for _ in 0..<1000 {
            if await gate.has(key) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Preview request did not reach the controlled renderer")
    }

    func testLateOldFrameCannotReplaceTheNewEdit() async throws {
        let gate = Gate()
        let model = ContentPreviewModel(render: { try await gate.render($0) }, delay: {})
        let old = Task { await model.update(request("old")) }
        try await wait("old", gate: gate)
        let new = Task { await model.update(request("new")) }
        try await wait("new", gate: gate)
        let latest = try image(0x7F)
        await gate.finish("new", image: latest)
        await new.value
        XCTAssertTrue(model.image === latest)
        await gate.finish("old", image: try image(0))
        await old.value
        XCTAssertTrue(model.image === latest)
        XCTAssertFalse(model.isRendering)
    }

    func testCancellationAndClosingCannotPublishLatePixels() async throws {
        for close in [false, true] {
            let gate = Gate()
            let model = ContentPreviewModel(render: { try await gate.render($0) }, delay: {})
            let task = Task { await model.update(request("pending")) }
            try await wait("pending", gate: gate)
            if close { model.cancel() } else { task.cancel() }
            await gate.finish("pending", image: try image(0))
            await task.value
            XCTAssertNil(model.image)
            XCTAssertNil(model.error)
            XCTAssertFalse(model.isRendering)
        }
    }

    func testFailureClearsOldFrameAndExplainsInvalidDraft() async throws {
        let raster = try image(0)
        let model = ContentPreviewModel(render: { request in
            if request.card?.id == "bad" { throw ContentCard.ValidationError.text(field: "title", maximumBytes: 24) }
            return raster
        }, delay: {})
        await model.update(request("valid"))
        XCTAssertNotNil(model.image)
        await model.update(request("bad"))
        XCTAssertNil(model.image)
        XCTAssertTrue(model.error?.contains("24 UTF-8 bytes") == true)
        XCTAssertFalse(model.isRendering)
    }

    func testBundledFontAndNativeKoreanPreviewWorkWithoutAReader() async throws {
        let font = try await PreviewFontStore.shared.font()
        XCTAssertEqual(font.count, 10_903_872)
        let notices = try await PreviewFontStore.shared.notices()
        XCTAssertTrue(notices.contains("SIL OPEN FONT LICENSE"))
        let model = ContentPreviewModel()
        await model.update(.init(card: .init(id: "korean", title: "오늘 한 줄", question: "무엇을 배웠나요?"),
                                 image: nil, hardware: .x3, orientation: .portrait))
        XCTAssertNil(model.error)
        XCTAssertEqual(model.image?.width, 528)
        XCTAssertEqual(model.image?.height, 792)
        let renderer = try HostRendererBridge(font: font, hardware: .x3)
        let expected = try await renderer.render(
            card: .init(id: "korean", title: "오늘 한 줄", question: "무엇을 배웠나요?"),
            options: PreviewStyle.reference.options)
        let actualImage = try XCTUnwrap(model.image)
        let expectedImage = try XCTUnwrap(expected.image())
        XCTAssertEqual(actualImage.dataProvider?.data as Data?, expectedImage.dataProvider?.data as Data?,
                       "Reference preview must distinguish previous and next navigation")
#if canImport(UIKit)
        let attachment = XCTAttachment(image: UIImage(cgImage: actualImage))
        attachment.name = "content-distinct-navigation"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
        let missing = PreviewFontStore(bundle: Bundle(for: Self.self))
        do {
            _ = try await missing.font()
            XCTFail("Missing bundled font accepted")
        } catch { XCTAssertEqual(error as? HostRendererBridge.Failure, .invalidFont) }
    }
}
