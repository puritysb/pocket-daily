import CryptoKit
import XCTest
@testable import Pocket

/// KOReader partial MD5 (`util.partialMD5`) and filename MD5 identities.
///
/// Golden values come from this Python mirror of the Lua algorithm:
///
///     import hashlib
///     def partial_md5(data):
///         m = hashlib.md5()
///         for i in range(-1, 11):
///             offset = 0 if i < 0 else 1024 << (2 * i)
///             if offset >= len(data):
///                 break
///             m.update(data[offset:offset + 1024])
///         return m.hexdigest()
///     def pattern(n):
///         return bytes(((i * 7 + (i >> 8)) & 0xFF) for i in range(n))
///     partial_md5(pattern(n))
///     hashlib.md5("Moby Dick.epub".encode()).hexdigest()
final class KOReaderDocumentDigestTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KOReaderDigestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pattern(_ count: Int) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 8)) })
    }

    private func write(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).epub")
        try data.write(to: url)
        return url
    }

    /// Independent reference: explicit offsets 0, 1024, 4096, ..., 1024 << 20.
    private func reference(_ data: Data) -> String {
        var offsets = [0]
        for shift in stride(from: 0, through: 20, by: 2) {
            offsets.append(1_024 << shift)
        }
        var sampled = Data()
        for offset in offsets {
            if offset >= data.count { break }
            sampled.append(data[offset ..< min(offset + 1_024, data.count)])
        }
        return Insecure.MD5.hash(data: sampled).map { String(format: "%02x", $0) }.joined()
    }

    func testOffsetsMatchKOReader() {
        XCTAssertEqual(KOReaderDocumentDigest.sampleOffsets.count, 12)
        XCTAssertEqual(KOReaderDocumentDigest.sampleOffsets.prefix(4), [0, 1_024, 4_096, 16_384])
        XCTAssertEqual(KOReaderDocumentDigest.sampleOffsets.last, 1_024 << 20)
    }

    func testEmptyFileHashesNothing() throws {
        let url = try write(Data())
        XCTAssertEqual(try KOReaderDocumentDigest.partialMD5(of: url), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(KOReaderDocumentDigest.partialMD5(of: Data()), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testBoundarySizesMatchReferenceForFileAndData() throws {
        for size in [1, 1_000, 1_023, 1_024, 1_025, 2_048, 4_095, 4_096, 4_097, 16_384, 16_385, 20_000] {
            let data = pattern(size)
            let url = try write(data)
            let expected = reference(data)
            XCTAssertEqual(try KOReaderDocumentDigest.partialMD5(of: url), expected, "file size \(size)")
            XCTAssertEqual(KOReaderDocumentDigest.partialMD5(of: data), expected, "data size \(size)")
        }
    }

    func testGoldenVectorsFromPythonMirror() throws {
        let golden: [(Int, String)] = [
            (1, "93b885adfe0da089cdf634904fd59f71"),
            (1_000, "bd8c10439abeb42fb5c19745991e360e"),
            (1_024, "e3c38a26dde2f1240488828012116299"),
            (1_025, "a7012636ea832538a0764e75f7fa2443"),
            (4_096, "6cba2e24447ac1390fd3b673ef494722"),
            (4_097, "efea8dae7ef9d026a0c00997267b6130"),
            (20_000, "3d2446ce93e0a44ec6da372b3275944a"),
        ]
        for (size, digest) in golden {
            let url = try write(pattern(size))
            XCTAssertEqual(try KOReaderDocumentDigest.partialMD5(of: url), digest, "size \(size)")
        }
    }

    func testLargeFileMatchesGoldenAndReference() throws {
        let data = pattern(5 * 1_024 * 1_024)
        let url = try write(data)
        let digest = try KOReaderDocumentDigest.partialMD5(of: url)
        XCTAssertEqual(digest, "f4f5bd53afa9222c58bdfe8ae0be6340")
        XCTAssertEqual(digest, reference(data))
        XCTAssertEqual(KOReaderDocumentDigest.partialMD5(of: data), digest)
    }

    func testDataSliceWithNonZeroStartIndex() {
        let data = pattern(6_000)
        let slice = data[1_000 ..< 6_000]
        XCTAssertEqual(KOReaderDocumentDigest.partialMD5(of: slice), reference(Data(slice)))
    }

    func testMissingFileThrows() {
        let url = directory.appendingPathComponent("missing.epub")
        XCTAssertThrowsError(try KOReaderDocumentDigest.partialMD5(of: url))
    }

    func testDigestIsLowercaseHex() throws {
        let digest = try KOReaderDocumentDigest.partialMD5(of: write(pattern(3_000)))
        XCTAssertEqual(digest.count, 32)
        XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertTrue(KOReaderDocumentDigest.isDigest(digest))
    }

    func testFilenameDigestUsesLastPathComponent() {
        XCTAssertEqual(KOReaderDocumentDigest.filenameMD5("Moby Dick.epub"), "cdd5016cf10439fc76ab08284361d586")
        XCTAssertEqual(
            KOReaderDocumentDigest.filenameMD5("/mnt/us/books/Moby Dick.epub"),
            "cdd5016cf10439fc76ab08284361d586"
        )
    }

    func testDigestValidation() {
        XCTAssertTrue(KOReaderDocumentDigest.isDigest("d41d8cd98f00b204e9800998ecf8427e"))
        XCTAssertTrue(KOReaderDocumentDigest.isDigest("D41D8CD98F00B204E9800998ECF8427E"))
        XCTAssertFalse(KOReaderDocumentDigest.isDigest(""))
        XCTAssertFalse(KOReaderDocumentDigest.isDigest("d41d8cd98f00b204e9800998ecf8427"))
        XCTAssertFalse(KOReaderDocumentDigest.isDigest("d41d8cd98f00b204e9800998ecf8427e0"))
        XCTAssertFalse(KOReaderDocumentDigest.isDigest("g41d8cd98f00b204e9800998ecf8427e"))
        XCTAssertFalse(KOReaderDocumentDigest.isDigest("../d8cd98f00b204e9800998ecf8427e"))
    }
}
