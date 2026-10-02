import XCTest
import zlib
@testable import Pocket

/// The on-device library: EPUB inspection, byte-preserving import, text and
/// Markdown conversion, de-duplication and position persistence.
final class LibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEPUB(title: String = "Test Book", author: String = "Writer",
                          paragraphs: [String] = ["One.", "Two."]) async throws -> URL {
        let document = EPUBDocument(title: title, language: "ko", author: author,
                                    chapters: [.init(title: "Chapter", paragraphs: paragraphs)],
                                    identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                                    modified: Date(timeIntervalSince1970: 1_700_000_000))
        return try await EPUBExporter.write(document, to: root.appendingPathComponent("exports"))
    }

    // MARK: Inspection

    func testInspectReadsGeneratedPackageMetadata() async throws {
        let url = try await makeEPUB(title: "한글 제목", author: "작가")
        let info = try EPUBPackageReader.inspect(url)
        XCTAssertEqual(info.title, "한글 제목")
        XCTAssertEqual(info.author, "작가")
        XCTAssertEqual(info.language, "ko")
        XCTAssertEqual(info.spineCount, 1)
        XCTAssertFalse(info.identifier.isEmpty)
    }

    func testInspectRejectsNonArchivesAndTruncatedFiles() async throws {
        let text = root.appendingPathComponent("plain.epub")
        try Data("not a zip".utf8).write(to: text)
        XCTAssertThrowsError(try EPUBPackageReader.inspect(text)) {
            XCTAssertEqual($0 as? EPUBPackageError, .notAnArchive)
        }
        let valid = try Data(contentsOf: try await makeEPUB())
        let truncated = root.appendingPathComponent("truncated.epub")
        try valid.prefix(valid.count / 2).write(to: truncated)
        XCTAssertThrowsError(try EPUBPackageReader.inspect(truncated))
    }

    func testInflateDecodesRawDeflateAndRejectsSizeMismatch() throws {
        let original = Data(String(repeating: "<p>페이지 page</p>\n", count: 400).utf8)
        let compressed = try Self.rawDeflate(original)
        XCTAssertLessThan(compressed.count, original.count)
        XCTAssertEqual(try ZIPArchive.inflate(compressed, expected: original.count), original)
        XCTAssertThrowsError(try ZIPArchive.inflate(compressed, expected: original.count + 1))
        XCTAssertThrowsError(try ZIPArchive.inflate(Data([0xff, 0xff, 0xff]), expected: 10))
    }

    func testResolveHandlesRelativePackagePaths() {
        XCTAssertEqual(EPUBPackageReader.resolve("images/cover.jpg", relativeTo: "OEBPS/content.opf"), "OEBPS/images/cover.jpg")
        XCTAssertEqual(EPUBPackageReader.resolve("../cover%20art.png", relativeTo: "OEBPS/text/content.opf"), "OEBPS/cover art.png")
        XCTAssertEqual(EPUBPackageReader.resolve("cover.jpg#frag", relativeTo: "content.opf"), "cover.jpg")
    }

    // MARK: Import

    func testImportKeepsBytesAndDeduplicatesByDigest() async throws {
        let library = BookLibrary(root: root.appendingPathComponent("lib"))
        let source = try await makeEPUB()
        let book = try await library.importFile(at: source)
        let stored = try await library.fileURL(for: book)
        XCTAssertEqual(try Data(contentsOf: stored), try Data(contentsOf: source), "Library books keep the imported bytes")
        XCTAssertEqual(book.documentDigest, try KOReaderDocumentDigest.partialMD5(of: source))
        XCTAssertEqual(book.title, "Test Book")
        XCTAssertEqual(book.origin, .imported)

        let again = try await library.importFile(at: source)
        XCTAssertEqual(again.id, book.id)
        let count = try await library.books().count
        XCTAssertEqual(count, 1)
    }

    func testImportConvertsKoreanLegacyTextAndMarkdownChapters() async throws {
        let library = BookLibrary(root: root.appendingPathComponent("lib"))
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        let text = root.appendingPathComponent("소설.txt")
        try XCTUnwrap("첫 문단입니다.\n\n둘째 문단입니다.".data(using: cp949)).write(to: text)
        let book = try await library.importFile(at: text)
        XCTAssertEqual(book.title, "소설")
        XCTAssertEqual(book.origin, .written)
        let stored = try await library.fileURL(for: book)
        XCTAssertEqual(stored.pathExtension, "epub")

        let document = BookLibrary.document(title: "Notes", text: "Intro line\n\n# First\n\nAlpha\n\n## Second ##\n\nBeta\n\nGamma", markdown: true)
        XCTAssertEqual(document.chapters.map(\.title), ["Notes", "First", "Second"])
        XCTAssertEqual(document.chapters.last?.paragraphs, ["Beta", "Gamma"])
    }

    func testConvertedTextIsTheSameBookOnEveryDevice() async throws {
        let text = "첫 문단입니다.\n\n둘째 문단입니다."
        let first = try await EPUBExporter.write(BookLibrary.document(title: "소설", text: text, markdown: false),
                                                 to: root.appendingPathComponent("a"))
        let second = try await EPUBExporter.write(BookLibrary.document(title: "소설", text: text, markdown: false),
                                                  to: root.appendingPathComponent("b"))
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second), "Same text converts to the same bytes")
        XCTAssertEqual(try KOReaderDocumentDigest.partialMD5(of: first), try KOReaderDocumentDigest.partialMD5(of: second))
        XCTAssertNotEqual(BookLibrary.stableIdentifier(title: "소설", text: text, markdown: false),
                          BookLibrary.stableIdentifier(title: "소설", text: text + "\n\n셋째", markdown: false))
    }

    func testImportRejectsUnsupportedAndEmptyFiles() async throws {
        let library = BookLibrary(root: root.appendingPathComponent("lib"))
        let pdf = root.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.7".utf8).write(to: pdf)
        do {
            _ = try await library.importFile(at: pdf)
            XCTFail("PDF must be rejected")
        } catch {
            XCTAssertEqual(error as? LibraryError, .unsupportedFormat("pdf"))
        }
        let xtc = root.appendingPathComponent("book.xtc")
        try Data([1, 2, 3]).write(to: xtc)
        do {
            _ = try await library.importFile(at: xtc)
            XCTFail("XTC must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Reader → Files"))
        }
        XCTAssertThrowsError(try BookLibrary.decodeText(Data("  \n ".utf8))) {
            XCTAssertEqual($0 as? LibraryError, .emptyText)
        }
        XCTAssertEqual(try BookLibrary.decodeText(Data([0xef, 0xbb, 0xbf] + Array("BOM".utf8))), "BOM")
    }

    func testPositionsPersistAndRemovalDeletesFolder() async throws {
        let library = BookLibrary(root: root.appendingPathComponent("lib"))
        let book = try await library.importFile(at: try await makeEPUB())
        let position = ReadingPosition(fraction: 0.42, xpointer: "/body/DocFragment[1]/body/p[2]/text().3",
                                       cfi: "epubcfi(/6/2!/4/2,/1:0,/1:1)", chapter: "Chapter",
                                       updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await library.update(book.id) { $0.position = position }
        let books = try await library.books()
        let reloaded = try XCTUnwrap(books.first)
        XCTAssertEqual(reloaded.position, position)
        XCTAssertEqual(reloaded.progress, 0.42, accuracy: 0.0001)

        let folder = try await library.fileURL(for: book).deletingLastPathComponent()
        try await library.remove(book.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let remaining = try await library.books()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testWelcomeBookIsDeterministicAndValid() async throws {
        let first = try await EPUBExporter.write(WelcomeBook.document, to: root.appendingPathComponent("a"))
        let second = try await EPUBExporter.write(WelcomeBook.document, to: root.appendingPathComponent("b"))
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        let info = try EPUBPackageReader.inspect(first)
        XCTAssertEqual(info.title, "Welcome to Pocket Daily")
        XCTAssertGreaterThanOrEqual(info.spineCount, 4)
    }

    static func rawDeflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CocoaError(.featureUnsupported) }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let status: Int32 = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw CocoaError(.featureUnsupported) }
        return output.prefix(Int(stream.total_out))
    }
}
