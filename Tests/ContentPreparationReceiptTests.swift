import XCTest
@testable import Pocket

final class ContentPreparationReceiptTests: XCTestCase {
    private func target() throws -> ContentRevision {
        let image = try ContentImage(width: 1, height: 1, raster: Data([0])).encoded()
        return try ContentRevision(cards: [.init(id: "a", title: "A", question: "Text", imagePath: "sun.pbm")],
                                   images: ["sun.pbm": image])
    }
    private func response(_ target: ContentRevision, mask: String, count: Int = 2, id: String = "reader", schema: Int = 1) -> Data {
        Data("{\"schema\":\(schema),\"deviceID\":\"\(id)\",\"revision\":\"\(target.revision)\",\"fileCount\":\(count),\"verifiedMask\":\(mask)}".utf8)
    }
    func testMapsCanonicalBitsToExactAssets() throws {
        let target = try target()
        for mask in 0...3 {
            let receipt = try ContentPreparationReceipt.decode(response(target, mask: String(mask)), target: target, deviceID: "reader")
            let expected = target.files.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            XCTAssertEqual(receipt.verifiedFiles.map(\.path), expected.map(\.path))
            XCTAssertEqual(receipt.verifiedFiles.map(\.sha256), expected.map(\.sha256))
            XCTAssertEqual(receipt.destination.revision, target.revision)
        }
    }
    func testRejectsWrongIdentitySchemaCountAndOutOfRangeBits() throws {
        let target = try target()
        for bytes in [response(target, mask: "3", id: "other"), response(target, mask: "3", schema: 2),
                      response(target, mask: "3", count: 1), response(target, mask: "4"),
                      response(target, mask: "65536"), response(target, mask: "-1"),
                      response(target, mask: "true"), response(target, mask: "1.5")] {
            XCTAssertThrowsError(try ContentPreparationReceipt.decode(bytes, target: target, deviceID: "reader"))
        }
        let other = try ContentRevision(cards: [])
        XCTAssertThrowsError(try ContentPreparationReceipt.decode(response(target, mask: "0"), target: other, deviceID: "reader"))
    }
    func testEmptyRevisionRequiresEmptyMask() throws {
        let target = try ContentRevision(cards: [])
        XCTAssertTrue(try ContentPreparationReceipt.decode(response(target, mask: "0", count: 0), target: target, deviceID: "reader").verifiedFiles.isEmpty)
        XCTAssertThrowsError(try ContentPreparationReceipt.decode(response(target, mask: "1", count: 0), target: target, deviceID: "reader"))
    }
}
