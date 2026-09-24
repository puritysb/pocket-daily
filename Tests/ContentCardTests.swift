import CryptoKit
import XCTest
@testable import Pocket

final class ContentCardTests: XCTestCase {
    func testLayoutV2GoldenAndOldDraftCompatibility() throws {
        var card = ContentCard(id: "morning-1", title: "오늘", question: "한 줄 읽기\nRead one line.",
                               context: "가볍게 시작하세요.", imagePath: "sun.pbm")
        let fixtures: [(ContentCard.Layout, [UInt8], String)] = [
            (.imageFirst, [0xe9, 0x45, 0x35, 0xc5], "2241823c074d4eb1237d095728a19dac8164a133df88a1604539e55e9ffb42a7"),
            (.sideBySide, [0x6d, 0x1e, 0xaf, 0x96], "29bb83d25205c6d23a9af2047e301f8832e07a9b0e4d996dcea17c9bb6ec04e5")
        ]
        for (layout, crc, hash) in fixtures {
            card.layout = layout
            let bytes = try card.encoded()
            XCTAssertEqual(bytes[4], 2)
            XCTAssertEqual(bytes[491], layout.rawValue)
            XCTAssertEqual(Array(bytes.suffix(4)), crc)
            XCTAssertEqual(ContentManifest.revision(of: bytes), hash)
            XCTAssertEqual(try JSONDecoder().decode(ContentCard.self, from: JSONEncoder().encode(card)), card)
        }
        let old = Data(#"{"id":"a","title":"A","question":"B","context":"","imagePath":""}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ContentCard.self, from: old).layout, .textFirst)
        let unknown = Data(#"{"id":"a","title":"A","question":"B","context":"","imagePath":"","layout":3}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ContentCard.self, from: unknown))
    }

    func testFirmwareGoldenAndManifestComposition() throws {
        let card = ContentCard(id: "morning-1", title: "오늘", question: "한 줄 읽기\nRead one line.",
                               context: "가볍게 시작하세요.", imagePath: "sun.pbm")
        let bytes = try card.encoded()
        XCTAssertEqual(bytes.count, 512)
        XCTAssertEqual(Array(bytes.suffix(4)), [0x8D, 0x91, 0xC2, 0x56])
        XCTAssertEqual(ContentManifest.revision(of: bytes), "dc6d7e86f5ac0a6114fc6f49ea62572874a355e0a250e01b663508a805d6e1dc")
        let entry = try ContentManifest.File(path: "morning.card", kind: .card, content: bytes)
        XCTAssertEqual(entry.bytes, 512)
        XCTAssertEqual(entry.sha256, Data(SHA256.hash(data: bytes)))
        XCTAssertNoThrow(try ContentManifest.encode([entry]))
        // Manifest composition alone does not resolve/validate the image file.
    }

    func testUTF8LimitsAreBytesAndNeverTruncate() throws {
        var card = ContentCard(id: "a", title: String(repeating: "한", count: 8), question: String(repeating: "x", count: 160),
                               context: String(repeating: "y", count: 191))
        XCTAssertNoThrow(try card.encoded())
        card.title += "a"
        XCTAssertThrowsError(try card.encoded())
        card.title = "Title"
        card.question += "a"
        XCTAssertThrowsError(try card.encoded())
        card.question = "Text"
        card.context += "a"
        XCTAssertThrowsError(try card.encoded())
    }

    func testControlsAndEmptyRequiredFieldsRejected() throws {
        for text in ["", "a\0b", "a\rb", "a\tb", "a\u{7F}b", "a\u{85}b"] {
            XCTAssertThrowsError(try ContentCard(id: "a", title: text, question: "text").encoded())
            XCTAssertThrowsError(try ContentCard(id: "a", title: "Title", question: text).encoded())
        }
        XCTAssertThrowsError(try ContentCard(id: "a", title: "a\nb", question: "Text").encoded())
        XCTAssertNoThrow(try ContentCard(id: "a", title: "Title", question: "a\nb", context: "c\nd").encoded())
    }

    func testIdentifiersAndImagePathsCannotInvokeOrEscape() throws {
        for id in ["", "a/b", "../id", "ID", "한", String(repeating: "a", count: 33)] {
            XCTAssertThrowsError(try ContentCard(id: id, title: "Title", question: "Text").encoded())
        }
        XCTAssertNoThrow(try ContentCard(id: String(repeating: "a", count: 32), title: "Title", question: "Text").encoded())
        for path in ["../sun.pbm", "https://x/sun.pbm", "sun.card", "sun\0.pbm"] {
            XCTAssertThrowsError(try ContentCard(id: "a", title: "Title", question: "Text", imagePath: path).encoded())
        }
    }
}
