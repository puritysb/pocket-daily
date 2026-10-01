import XCTest
@testable import Pocket

final class ReaderShelfTests: XCTestCase {
    private func book(_ fileName: String, size: Int64, digest: String, article: Bool = false) -> LibraryBook {
        LibraryBook(id: UUID(), title: fileName, author: "", language: "en", fileName: fileName, byteCount: size,
                    documentDigest: digest, origin: article ? .article(UUID()) : .imported, addedAt: Date(),
                    lastOpenedAt: nil, hasCover: false, position: nil)
    }

    private func entry(_ path: String?, _ digest: String, _ percentage: Double) -> ReaderReadingEntry {
        ReaderReadingEntry(path: path, document: digest, filenameDocument: nil, progress: nil,
                           percentage: percentage, updated: nil, seq: nil)
    }

    private let digestA = String(repeating: "a", count: 32)
    private let digestB = String(repeating: "b", count: 32)
    private let digestC = String(repeating: "c", count: 32)

    func testBooksTheAppSentMatchByNameAndSize() {
        let sent = book("Pride.epub", size: 1000, digest: digestA)
        let inventory = ReaderInventory(deviceID: "1234ABCD", model: "X4", files: [
            .init(path: "/Pride.epub", size: 1000),
            .init(path: "/Pride copy.epub", size: 1000),
            .init(path: "/Other.epub", size: 999),
            .init(path: "/notes.bin", size: 10),
        ], reading: [], readAt: Date())
        let shelf = ReaderShelf(inventory: inventory, books: [sent])
        XCTAssertEqual(shelf.item(for: sent)?.path, "/Pride.epub")
        XCTAssertEqual(shelf.onlyOnReader.map(\.path), ["/Other.epub", "/Pride copy.epub"],
                       "Non-book files are not shelved; a renamed copy is not assumed to be the same book")
    }

    func testReaderFingerprintMatchesAndCarriesItsPlace() {
        let renamed = book("Mine.epub", size: 500, digest: digestB)
        let elsewhere = book("Deep.epub", size: 700, digest: digestC)
        let inventory = ReaderInventory(deviceID: "1234ABCD", model: nil, files: [
            .init(path: "/Renamed on reader.epub", size: 500),
        ], reading: [
            entry("/Renamed on reader.epub", digestB.uppercased(), 0.43),
            entry("/Books/Deep.epub", digestC, 0.9),
            entry(nil, digestA, 0.1),
        ], readAt: Date())
        let shelf = ReaderShelf(inventory: inventory, books: [renamed, elsewhere])
        XCTAssertEqual(shelf.item(for: renamed)?.percentage, 0.43)
        XCTAssertEqual(shelf.item(for: renamed)?.document, digestB, "Fingerprints compare in lower case")
        XCTAssertEqual(shelf.item(for: elsewhere)?.path, "/Books/Deep.epub", "Recent books outside the root still match")
        XCTAssertTrue(shelf.onlyOnReader.isEmpty, "A recent book with no path and no Library match is not listed")
    }

    func testOnlyEPUBCopiesCanJoinTheLibraryAndArticlesAreSeparate() {
        let inventory = ReaderInventory(deviceID: "1234ABCD", model: "X3", files: [
            .init(path: "/Book.epub", size: 10),
            .init(path: "/Notes.txt", size: 10),
            .init(path: "/Rendered.xtc", size: 10),
            .init(path: "/Articles/pd-article-1.epub", size: 10),
        ], reading: [], readAt: Date())
        let items = Dictionary(uniqueKeysWithValues: ReaderShelf(inventory: inventory, books: []).items.map { ($0.path, $0) })
        XCTAssertEqual(items["/Book.epub"]?.canAddToLibrary, true)
        XCTAssertEqual(items["/Notes.txt"]?.canAddToLibrary, false, "TXT is converted on import and would not match again")
        XCTAssertEqual(items["/Rendered.xtc"]?.canAddToLibrary, false)
        XCTAssertEqual(items["/Articles/pd-article-1.epub"]?.isArticle, true)
    }
}

// MARK: Piece download

@MainActor
final class ReaderFileDownloaderTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private final class Sleeps: @unchecked Sendable { var values: [Duration] = [] }

    private func downloader(_ sleeps: Sleeps) -> ReaderFileDownloader {
        var downloader = ReaderFileDownloader()
        downloader.sleep = { sleeps.values.append($0) }
        return downloader
    }

    func testPiecesOfAnySizeAdvanceByWhatArrived() async throws {
        let bytes = Data((0..<10_000).map { UInt8($0 % 251) })
        var offsets: [Int64] = []
        let file = folder.appendingPathComponent("book.epub")
        try await downloader(Sleeps()).download(size: Int64(bytes.count), to: file, fetch: { offset in
            offsets.append(offset)
            let length = offset == 0 ? 4096 : 1024 // the reader picks each piece's size
            return .data(bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + length)))
        }, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(offsets.prefix(3), [0, 4096, 5120])
    }

    func testBusyReaderIsRetriedAtTheSameOffsetWithBackoff() async throws {
        let sleeps = Sleeps()
        var replies: [ReaderFilePiece] = [.busy, .busy, .busy, .busy, .busy, .data(Data("abc".utf8))]
        var offsets: [Int64] = []
        let file = folder.appendingPathComponent("busy.epub")
        try await downloader(sleeps).download(size: 3, to: file, fetch: { offset in
            offsets.append(offset); return replies.removeFirst()
        }, progress: { _ in })
        XCTAssertEqual(sleeps.values, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(4)])
        XCTAssertEqual(Set(offsets), [0])
    }

    func testAReaderThatStaysBusyStopsTheCopy() async {
        var downloader = downloader(Sleeps())
        downloader.busyLimit = 3
        do {
            try await downloader.download(size: 3, to: folder.appendingPathComponent("x"),
                                          fetch: { _ in .busy }, progress: { _ in })
            XCTFail("A reader that never answers must not hang the copy")
        } catch { XCTAssertEqual(error as? ReaderDownloadError, .readerBusy) }
    }

    func testAChangedFileRestartsOnceFromTheStart() async throws {
        var replies: [ReaderFilePiece] = [.data(Data("ab".utf8)), .changed, .data(Data("xy".utf8)), .data(Data("z".utf8))]
        var offsets: [Int64] = []
        let file = folder.appendingPathComponent("changed.epub")
        try await downloader(Sleeps()).download(size: 3, to: file, fetch: { offset in
            offsets.append(offset); return replies.removeFirst()
        }, progress: { _ in })
        XCTAssertEqual(offsets, [0, 2, 0, 2])
        XCTAssertEqual(try Data(contentsOf: file), Data("xyz".utf8), "Bytes from before the change are discarded")

        var again: [ReaderFilePiece] = [.changed, .changed]
        do {
            try await downloader(Sleeps()).download(size: 3, to: folder.appendingPathComponent("y"),
                                                    fetch: { _ in again.removeFirst() }, progress: { _ in })
            XCTFail("A file that keeps changing must not loop")
        } catch { XCTAssertEqual(error as? ReaderDownloadError, .changedTwice) }
    }

    func testEmptyOrOverlongPiecesAreRejected() async {
        for piece in [Data(), Data("toolong".utf8)] {
            do {
                try await downloader(Sleeps()).download(size: 3, to: folder.appendingPathComponent("bad"),
                                                        fetch: { _ in .data(piece) }, progress: { _ in })
                XCTFail("Malformed piece accepted")
            } catch { XCTAssertEqual(error as? ReaderDownloadError, .malformedPiece) }
        }
    }

    func testCopyMustMatchTheReaderFingerprint() throws {
        let file = folder.appendingPathComponent("book.epub")
        let bytes = Data((0..<5000).map { UInt8($0 % 7) })
        try bytes.write(to: file)
        let digest = KOReaderDocumentDigest.partialMD5(of: bytes)
        XCTAssertNoThrow(try ReaderFileDownloader.verify(file, document: digest.uppercased()))
        XCTAssertNoThrow(try ReaderFileDownloader.verify(file, document: nil))
        XCTAssertThrowsError(try ReaderFileDownloader.verify(file, document: String(repeating: "0", count: 32))) {
            XCTAssertEqual($0 as? ReaderDownloadError, .fingerprintMismatch)
        }
    }
}

// MARK: Piece request

private final class PieceURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(Self.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ReaderFilePieceRequestTests: XCTestCase {
    private func client() -> (CrossPointClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PieceURLProtocol.self]
        let session = URLSession(configuration: config)
        return (CrossPointClient(session: session), session)
    }

    func testStatusCodesMapToTheContract() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        func piece() async throws -> ReaderFilePiece {
            try await client.readerFilePiece(identity: "1234ABCD", path: "/Book.epub", size: 10, offset: 4,
                                             host: "reader.test", port: 80)
        }
        PieceURLProtocol.status = 200; PieceURLProtocol.body = Data("abc".utf8)
        let first = try await piece()
        XCTAssertEqual(first, .data(Data("abc".utf8)))
        let query = URLComponents(url: try XCTUnwrap(PieceURLProtocol.lastURL), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(PieceURLProtocol.lastURL?.path, "/api/pocket/v1/files/content")
        XCTAssertEqual(Set(query ?? []), [URLQueryItem(name: "deviceID", value: "1234ABCD"),
                                          URLQueryItem(name: "path", value: "/Book.epub"),
                                          URLQueryItem(name: "size", value: "10"),
                                          URLQueryItem(name: "offset", value: "4")])
        PieceURLProtocol.status = 503; PieceURLProtocol.body = Data()
        let busy = try await piece()
        XCTAssertEqual(busy, .busy)
        PieceURLProtocol.status = 409
        let changed = try await piece()
        XCTAssertEqual(changed, .changed)
        for status in [403, 404, 416, 500] {
            PieceURLProtocol.status = status
            do { _ = try await piece(); XCTFail("HTTP \(status) accepted") } catch {}
        }
        PieceURLProtocol.status = 200; PieceURLProtocol.body = Data(count: 4097)
        do { _ = try await piece(); XCTFail("Oversized piece accepted") }
        catch { XCTAssertEqual(error as? ReaderDownloadError, .malformedPiece) }
    }
}
