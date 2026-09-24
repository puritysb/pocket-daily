import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Pocket

final class ContentImageImportTests: XCTestCase {
    func testPreviewPreservesPixelPolarityRowsAndIgnoresPadding() throws {
        let source = try ContentImage(width: 9, height: 2, raster: Data([0xAA, 0x80, 0x55, 0]))
        let preview = try XCTUnwrap(source.previewImage())
        XCTAssertEqual(preview.width, 9)
        XCTAssertEqual(preview.height, 2)
        XCTAssertEqual(preview.bytesPerRow, 9)
        let pixels = try XCTUnwrap(preview.dataProvider?.data) as Data
        XCTAssertEqual(pixels, Data([0,255,0,255,0,255,0,255,0, 255,0,255,0,255,0,255,0,255]))
    }

    @MainActor
    func testRemovalRetainsSharedImageUntilLastReference() throws {
        let editor = ContentEditorModel(store: ContentDraftStore(file: URL(fileURLWithPath: "/unused-test-draft")))
        editor.edit(.init(cards: [.init(id: "a", title: "A", question: "Text"),
                                 .init(id: "b", title: "B", question: "Text")]))
        let black = try ContentImageImport.convert(Data([80,52,10,49,32,49,10,0x80]))
        try editor.attachImage(black, cardID: "a")
        try editor.attachImage(black, cardID: "b")
        try editor.removeImage(cardID: "a")
        XCTAssertEqual(editor.draft.cards[0].imagePath, "")
        XCTAssertEqual(editor.draft.images.count, 1)
        let before = editor.draft
        XCTAssertThrowsError(try editor.removeImage(cardID: "missing"))
        XCTAssertEqual(editor.draft, before)
        try editor.removeImage(cardID: "b")
        XCTAssertTrue(editor.draft.images.isEmpty)
        XCTAssertEqual(try editor.deploymentSnapshot().files.count, 2)
    }

    private func png(width: Int, height: Int, rgba: Data) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: rgba as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testPNGConversionPreservesRowsAndFlattensTransparencyOnWhite() throws {
        let rgba = Data([0,0,0,255, 255,255,255,255, 0,0,0,0,
                         255,255,255,255, 0,0,0,255, 0,0,0,255])
        let imported = try ContentImageImport.convert(png(width: 3, height: 2, rgba: rgba))
        let image = try ContentImage.decode(imported.data)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.raster, Data([0x80, 0x60]))
        XCTAssertTrue(ContentManifest.validPath(imported.path, kind: .monoImage))
    }

    func testCanonicalPBMRemainsByteExactAndNamesAreDeterministic() throws {
        let bytes = Data([80,52,10,57,32,50,10,0xAA,0x80,0x55,0])
        let first = try ContentImageImport.convert(bytes)
        let second = try ContentImageImport.convert(bytes)
        XCTAssertEqual(first.data, bytes)
        XCTAssertEqual(first.path, second.path)
        XCTAssertEqual(first.width, 9)
        XCTAssertEqual(first.height, 2)
    }

    func testLargeImageDownsamplesWithinDeviceBounds() throws {
        let source = try png(width: 1024, height: 256, rgba: Data(repeating: 255, count: 1024 * 256 * 4))
        let imported = try ContentImageImport.convert(source)
        XCTAssertEqual(imported.width, 512)
        XCTAssertEqual(imported.height, 128)
        XCTAssertEqual(try ContentImage.decode(imported.data).raster, Data(repeating: 0, count: 64 * 128))
    }

    func testThresholdAndPaddingMatchFirmwareGolden() throws {
        var rgba = Data()
        for value: UInt8 in [0,255,0,255,0,255,0,255,0, 255,0,255,0,255,0,255,0,255] {
            rgba.append(contentsOf: [value, value, value, 255])
        }
        let image = try ContentImageImport.monochrome(width: 9, height: 2, opaqueRGBA: rgba)
        XCTAssertEqual(image.encoded(), Data([80,52,10,57,32,50,10,0xAA,0x80,0x55,0]))
        let boundary = try ContentImageImport.monochrome(width: 2, height: 1,
                                                        opaqueRGBA: Data([127,127,127,255,128,128,128,255]))
        XCTAssertEqual(boundary.raster, Data([0x80]))
    }

    func testMalformedAndOversizedSourcesFail() {
        for bytes in [Data(), Data("not an image".utf8), Data(repeating: 0, count: ContentImageImport.maximumFileBytes + 1),
                      Data([80,52,10,49,32,49,10,0x81])] {
            XCTAssertThrowsError(try ContentImageImport.convert(bytes))
        }
        XCTAssertThrowsError(try ContentImageImport.monochrome(width: 513, height: 1, opaqueRGBA: Data()))
    }

    @MainActor
    func testEditorAttachmentReplacesOnlyUnreferencedImagesAndBuildsRevision() throws {
        let editor = ContentEditorModel(store: ContentDraftStore(file: URL(fileURLWithPath: "/unused-test-draft")))
        editor.edit(.init(cards: [.init(id: "a", title: "A", question: "Text"),
                                 .init(id: "b", title: "B", question: "Text")]))
        let black = try ContentImageImport.convert(Data([80,52,10,49,32,49,10,0x80]))
        let white = try ContentImageImport.convert(Data([80,52,10,49,32,49,10,0]))
        try editor.attachImage(black, cardID: "a")
        try editor.attachImage(black, cardID: "b")
        try editor.attachImage(white, cardID: "a")
        XCTAssertEqual(editor.draft.images.count, 2)
        try editor.attachImage(white, cardID: "b")
        XCTAssertEqual(editor.draft.images.count, 1)
        XCTAssertEqual(try editor.deploymentSnapshot().files.count, 3)
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    @MainActor
    func testRejectedAttachmentPreservesDraft() throws {
        let editor = ContentEditorModel(store: ContentDraftStore(file: URL(fileURLWithPath: "/unused-test-draft")))
        editor.edit(.init(cards: [.init(id: "a", title: "A", question: "Text")]))
        let black = try ContentImageImport.convert(Data([80,52,10,49,32,49,10,0x80]))
        try editor.attachImage(black, cardID: "a")
        let before = editor.draft
        let collision = ContentImageImport.Imported(path: black.path, data: Data([80,52,10,49,32,49,10,0]), width: 1, height: 1)
        XCTAssertThrowsError(try editor.attachImage(collision, cardID: "a"))
        let wrongDimensions = ContentImageImport.Imported(path: black.path, data: black.data, width: 2, height: 1)
        XCTAssertThrowsError(try editor.attachImage(wrongDimensions, cardID: "a"))
        XCTAssertThrowsError(try editor.attachImage(black, cardID: "missing"))
        XCTAssertEqual(editor.draft, before)
    }
}
