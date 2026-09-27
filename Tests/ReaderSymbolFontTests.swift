import CryptoKit
import XCTest
@testable import Pocket

/// The bundled reader symbol font matches its pinned source and is sent to the
/// family folder the firmware scans, like the mounted-SD copy.
@MainActor
final class ReaderSymbolFontTests: XCTestCase {
    func testBundledFontMatchesItsPin() throws {
        let url = try XCTUnwrap(ReaderSymbolFont.bundledURL)
        let data = try Data(contentsOf: url)
        let folder = url.deletingLastPathComponent()
        let source = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("SOURCE.json"))) as? [String: Any])
        XCTAssertEqual(data.count, ReaderSymbolFont.byteCount)
        XCTAssertEqual(data.count, source["bytes"] as? Int)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), source["sha256"] as? String)
        for license in ["NotoEmoji-OFL.txt", "NotoSansSymbols2-OFL.txt", "NotoSansMath-OFL.txt"] {
            let text = try String(contentsOf: folder.appendingPathComponent(license), encoding: .utf8)
            XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE Version 1.1"), license)
        }
    }

    func testFontsTravelToTheirFamilyFolder() {
        let model = PocketModel()
        XCTAssertEqual(model.destination(for: URL(fileURLWithPath: "/tmp/PocketSymbols_12.cpfont")), "/.fonts/PocketSymbols")
        XCTAssertEqual(model.destination(for: URL(fileURLWithPath: "/tmp/RIDIBatang-16.cpfont")), "/.fonts/RIDIBatang")
        XCTAssertEqual(model.destination(for: URL(fileURLWithPath: "/tmp/book.epub")), "/")
        XCTAssertEqual(model.destination(for: URL(fileURLWithPath: "/tmp/words.pdl")), "/pocket-daily/learning")
    }
}
