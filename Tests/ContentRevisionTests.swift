import XCTest
@testable import Pocket

final class ContentRevisionTests: XCTestCase {
    func testCompleteRevisionMatchesFirmwareStoreGolden() throws {
        let card = ContentCard(id: "morning-1", title: "오늘", question: "한 줄 읽기\nRead one line.",
                               context: "가볍게 시작하세요.", imagePath: "sun.pbm")
        let image = try ContentImage(width: 9, height: 2, raster: Data([0xAA, 0x80, 0x55, 0])).encoded()
        let revision = try ContentRevision(cards: [card], images: ["sun.pbm": image])
        // Firmware verifies these actual files and SHA-256 values through the
        // production ContentRevisionStore implementation, backed by a fake HAL.
        XCTAssertEqual(revision.revision, "77a7e4638640e81c9e380134ea28581928d55d001c0e625f492b7c106e5e2b8b")
        XCTAssertEqual(revision.manifest.count, 228)
        XCTAssertEqual(revision.files.reduce(0) { $0 + $1.data.count }, 523)
    }

    func testPBMMatchesFirmwareGoldenAndRoundTrips() throws {
        let image = try ContentImage(width: 9, height: 2, raster: Data([0xAA, 0x80, 0x55, 0]))
        let golden = Data([80, 52, 10, 57, 32, 50, 10, 0xAA, 0x80, 0x55, 0])
        XCTAssertEqual(image.encoded(), golden)
        XCTAssertEqual(try ContentImage.decode(golden), image)
        // A raster byte that happens to be LF/#/space is still pixel data.
        for byte: UInt8 in [10, 35, 32] {
            let bytes = Data("P4\n8 1\n".utf8) + Data([byte])
            XCTAssertEqual(try ContentImage.decode(bytes).encoded(), bytes)
        }
    }

    func testImageRejectsMalformedOrNoncanonicalInputs() throws {
        for header in ["P1\n1 1\n", "P4\r\n1 1\n", "P4\n01 1\n", "P4\n0 1\n", "P4\n513 1\n", "P4\n1 0\n", "P4\n1 513\n", "P4\n#hi\n1 1\n", "P4\n1  1\n"] {
            XCTAssertThrowsError(try ContentImage.decode(Data(header.utf8) + Data([0])))
        }
        XCTAssertThrowsError(try ContentImage(width: 1, height: 1, raster: Data([1])))
        XCTAssertThrowsError(try ContentImage(width: Int.max, height: 1, raster: Data()))
        let valid = try ContentImage(width: 1, height: 1, raster: Data([0x80])).encoded()
        XCTAssertThrowsError(try ContentImage.decode(valid.dropLast()))
        XCTAssertThrowsError(try ContentImage.decode(valid + Data([0])))
        let max = try ContentImage(width: 512, height: 512, raster: Data(repeating: 0, count: 32768))
        XCTAssertEqual(try ContentImage.decode(max.encoded()), max)
    }

    func testRevisionRequiresCompleteReferencesAndValidCards() throws {
        let image = try ContentImage(width: 1, height: 1, raster: Data([0x80])).encoded()
        let card = ContentCard(id: "a", title: "Title", question: "Text", imagePath: "sun.pbm")
        XCTAssertThrowsError(try ContentRevision(cards: [card]))
        XCTAssertThrowsError(try ContentRevision(cards: [], images: ["sun.pbm": image]))
        XCTAssertThrowsError(try ContentRevision(cards: [card, card], images: ["sun.pbm": image]))
        XCTAssertThrowsError(try ContentRevision(cards: [card], images: ["sun.pbm": Data([0])]))
        let revision = try ContentRevision(cards: [card], images: ["sun.pbm": image])
        XCTAssertEqual(revision.files.map(\.path), ["card-00-a.card", "sun.pbm"])
        XCTAssertEqual(revision.manifest[10], 3)
        XCTAssertEqual(revision.revision, ContentManifest.revision(of: revision.manifest))
    }

    func testSmallEditOnlyChangesCardAssetAndRetainsImage() throws {
        let image = try ContentImage(width: 1, height: 1, raster: Data([0x80])).encoded()
        let original = ContentCard(id: "a", title: "Before", question: "Text", imagePath: "sun.pbm")
        var changed = original
        changed.title = "After"
        let before = try ContentRevision(cards: [original], images: ["sun.pbm": image])
        let after = try ContentRevision(cards: [changed], images: ["sun.pbm": image])
        XCTAssertEqual(after.changedFiles(from: before).map(\.path), ["card-00-a.card"])
        XCTAssertTrue(before.changedFiles(from: before).isEmpty)
        XCTAssertEqual(after.changedFiles(from: nil).count, 2)
        XCTAssertNotEqual(before.revision, after.revision)
        XCTAssertEqual(before.files.first?.data, try original.encoded())
    }

    func testCardOrderAndRemovalChangeRevisionWithoutMutatingPrevious() throws {
        let a = ContentCard(id: "a", title: "A", question: "A")
        let b = ContentCard(id: "b", title: "B", question: "B")
        let before = try ContentRevision(cards: [a, b])
        let reordered = try ContentRevision(cards: [b, a])
        XCTAssertNotEqual(before.revision, reordered.revision)
        XCTAssertEqual(reordered.files.map(\.path), ["card-00-b.card", "card-01-a.card"])
        let empty = try ContentRevision(cards: [])
        XCTAssertNotEqual(empty.revision, before.revision)
        XCTAssertTrue(empty.files.isEmpty)
        XCTAssertTrue(empty.changedFiles(from: before).isEmpty) // new manifest, no asset upload/deletion
        XCTAssertEqual(before.files.count, 2)
    }
}
