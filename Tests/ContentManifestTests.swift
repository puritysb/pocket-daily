import CryptoKit
import XCTest
@testable import Pocket

final class ContentManifestTests: XCTestCase {
    func testMatchesFirmwareGoldenAndRevision() throws {
        // Same bytes in firmware test/content_manifest/ContentManifestTest.cpp.
        let golden = "5044434d01001000010001007c00000001000000050000002cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824612e636172640000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000059feb63f"
        let file = try ContentManifest.File(path: "a.card", kind: .card, content: Data("hello".utf8))
        let manifest = try ContentManifest.encode([file])
        XCTAssertEqual(manifest.map { String(format: "%02x", $0) }.joined(), golden)
        XCTAssertEqual(ContentManifest.revision(of: manifest), "f23bffd5b98b9c7a7ea75213b1c10d0c2691cb26ad372ba6f35f8c0dc2e534ae")
    }

    func testCanonicalOrderAndEmptyRevision() throws {
        let a = try ContentManifest.File(path: "a.card", kind: .card, content: Data([1]))
        let b = try ContentManifest.File(path: "b.pbm", kind: .monoImage, content: Data([2]))
        XCTAssertEqual(try ContentManifest.encode([a, b]), try ContentManifest.encode([b, a]))
        let empty = try ContentManifest.encode([])
        XCTAssertEqual(empty.count, 20)
        XCTAssertEqual(empty[10], 1)
        XCTAssertNotEqual(ContentManifest.revision(of: empty), ContentManifest.revision(of: try ContentManifest.encode([a])))
    }

    func testRejectsUnsafePathsAndDuplicates() throws {
        for path in ["../a.card", "/a.card", "dir/a.card", "a\\b.card", "a\0b.card", "한.card", "A.card", ".card", "a..card", "-a.card", String(repeating: "a", count: 59) + ".card"] {
            let file = try ContentManifest.File(path: path, kind: .card, content: Data([1]))
            XCTAssertThrowsError(try ContentManifest.encode([file]), path)
        }
        let a = try ContentManifest.File(path: "a.card", kind: .card, content: Data([1]))
        XCTAssertThrowsError(try ContentManifest.encode([a, a]))
        let longest = try ContentManifest.File(path: String(repeating: "a", count: 58) + ".card", kind: .card, content: Data([1]))
        XCTAssertNoThrow(try ContentManifest.encode([longest]))
    }

    func testBoundsAndDigestRequirements() throws {
        let sha = Data(repeating: 1, count: 32)
        for size: UInt32 in [0, 16 * 1024 + 1, UInt32.max] {
            XCTAssertThrowsError(try ContentManifest.encode([.init(path: "a.card", kind: .card, bytes: size, sha256: sha)]))
        }
        XCTAssertNoThrow(try ContentManifest.encode([.init(path: "a.card", kind: .card, bytes: 16 * 1024, sha256: sha)]))
        XCTAssertThrowsError(try ContentManifest.encode([.init(path: "a.card", kind: .card, bytes: 1, sha256: Data())]))
        for count in [4, 17] {
            let files = (0..<count).map { ContentManifest.File(path: "a\($0).card", kind: .card, bytes: 1, sha256: sha) }
            XCTAssertThrowsError(try ContentManifest.encode(files))
        }
        let images = (0..<16).map { ContentManifest.File(path: "a\($0).pbm", kind: .monoImage, bytes: 1, sha256: sha) }
        XCTAssertNoThrow(try ContentManifest.encode(images))
        XCTAssertThrowsError(try ContentManifest.encode(images + [.init(path: "z.pbm", kind: .monoImage, bytes: 1, sha256: sha)]))
        let large = (0..<5).map { ContentManifest.File(path: "a\($0).pbm", kind: .monoImage, bytes: 64 * 1024, sha256: sha) }
        XCTAssertNoThrow(try ContentManifest.encode(Array(large.prefix(4))))
        XCTAssertThrowsError(try ContentManifest.encode(large))
    }
}
