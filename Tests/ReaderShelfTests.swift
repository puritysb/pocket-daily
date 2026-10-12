import XCTest
@testable import Pocket

private final class InventoryURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let folder = query["path"] ?? "/"
        let cursor = Int(query["cursor"] ?? "0") ?? 0
        let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario")
        let partial = scenario == "partial.test" && folder == "/Articles"
        let endless = scenario == "endless.test"
        let missing = scenario == "missing.test" && folder == "/Articles"
        let body: [String: Any] = ["deviceID": "1234ABCD", "path": folder,
            "nextCursor": endless ? cursor + 32 : 0,
            "entries": folder == "/" ? [["name": "book.epub", "size": 10, "directory": false, "deletable": true]] : []]
        do {
            let bytes = try JSONSerialization.data(withJSONObject: body)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: partial ? 503 : missing ? 404 : 200,
                httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class ReaderInventoryModelTests: XCTestCase {
    private func inspect(host: String, _ verify: (PocketModel) throws -> Void) async throws {
        let name = "inventory-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(host, forKey: "Pocket.lastReaderHost")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InventoryURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Scenario": host]
        let session = URLSession(configuration: config)
        let model = PocketModel(client: CrossPointClient(session: session),
            sessionStorage: ReaderSessionStorage(root: folder, defaults: defaults))
        defer {
            model.pauseForBackground()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"X3","deviceID":"1234ABCD","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"readerFiles":1}"#.utf8))
        var busy = false
        let subscription = model.readerWorkActive.sink { busy = $0 }
        defer { subscription.cancel() }
        model.requestReaderInventoryRefresh()
        let deadline = Date().addingTimeInterval(5)
        while busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(busy, "Inventory must settle")
        try verify(model)
    }

    func testSecondaryFolderFailureKeepsUsefulFilesAndShowsIncompleteWarning() async throws {
        try await inspect(host: "partial.test") { model in
            XCTAssertEqual(model.readerInventory?.files.map(\.path), ["/book.epub"])
            XCTAssertTrue(model.readerInventoryError?.contains("/Articles") == true)
            XCTAssertTrue(model.readerInventoryError?.contains("Refresh") == true)
        }
    }

    func testEmptyOptionalFoldersAreComplete() async throws {
        try await inspect(host: "complete.test") { model in
            XCTAssertEqual(model.readerInventory?.files.map(\.path), ["/book.epub"])
            XCTAssertNil(model.readerInventoryError)
        }
    }

    func testMissingDestinationFolderIsEmptyRatherThanAConnectionFailure() async throws {
        try await inspect(host: "missing.test") { model in
            XCTAssertEqual(model.readerInventory?.files.map(\.path), ["/book.epub"])
            XCTAssertNil(model.readerInventoryError)
        }
    }

    func testUnterminatedPaginationDoesNotPublishAnApparentlyCompleteInventory() async throws {
        try await inspect(host: "endless.test") { model in
            XCTAssertNil(model.readerInventory)
            XCTAssertTrue(model.readerInventoryError?.contains("too long") == true)
        }
    }
}

final class ReaderShelfTests: XCTestCase {
    func testFirmwareDiagnosticsDoNotAppearAsBooksOrEraseInventory() {
        let paths = ["/crash_report.txt", "/CRASH_REPORT.1.TXT", "/crash_report.2.txt",
                     "/crash_report.3.txt", "/nearby_ap_log.txt", "/Books/crash_report.txt",
                     "/crash_report_notes.txt", "/Notes.txt"]
        let inventory = ReaderInventory(deviceID: "1234ABCD", model: "X3",
            files: paths.map { .init(path: $0, size: 100) },
            reading: [entry("/crash_report.txt", digestA, 0.5)], readAt: Date())
        let shelf = ReaderShelf(inventory: inventory, books: [])
        XCTAssertEqual(Set(shelf.items.map(\.path)), Set(paths.suffix(3)))
        XCTAssertEqual(inventory.files.map(\.path), paths, "Browse Files must retain every diagnostic")
    }

    func testReaderBooksFolderIsListedAndMixedCaseRecentPathKeepsDownloadMetadata() {
        XCTAssertTrue(ReaderInventory.folders.contains("/Books"))
        let inventory = ReaderInventory(deviceID: "1234ABCD", model: "X3", files: [
            .init(path: "/Books/Novel.epub", size: 500),
        ], reading: [entry("/books/Novel.epub", digestA, 0.4)], readAt: Date())
        let shelf = ReaderShelf(inventory: inventory, books: [])
        XCTAssertEqual(shelf.items.count, 1)
        XCTAssertEqual(shelf.items.first?.path, "/Books/Novel.epub")
        XCTAssertEqual(shelf.items.first?.percentage, 0.4)
        XCTAssertEqual(shelf.items.first?.document, digestA)
        XCTAssertEqual(shelf.items.first?.canAddToLibrary, true)
    }
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

@MainActor
final class ReaderDownloadOperationTests: XCTestCase {
    func testCancelledBeforeBodyCompletesExactlyOnce() {
        var callbacks = 0
        let operation = ReaderDownloadOperation(size: 20) { result in
            callbacks += 1
            guard case .failure(let error) = result else { return XCTFail("Unexpected success") }
            XCTAssertEqual(error as? ReaderDownloadError, .interrupted)
        }
        operation.drained()
        operation.drained()
        operation.finish(.success(URL(fileURLWithPath: "/unused")), phase: .completed)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(operation.phase, .cancelled)
        XCTAssertEqual(operation.requests, 0)
    }

    func testProgressDistinguishesBusyRestartAndCompletedDownload() {
        var callbacks = 0
        let operation = ReaderDownloadOperation(size: 20) { _ in callbacks += 1 }
        operation.note(.request); operation.note(.busy)
        XCTAssertEqual(operation.phase, .waitingForReader)
        operation.note(.request); operation.note(.received(10)); operation.note(.restart)
        XCTAssertEqual(operation.received, 0)
        operation.note(.request); operation.note(.received(20)); operation.note(.saving)
        XCTAssertEqual(operation.phase, .saving)
        operation.note(.verifying)
        operation.finish(.success(URL(fileURLWithPath: "/unused")), phase: .completed)
        operation.drained(); operation.note(.busy)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(operation.requests, 3)
        XCTAssertEqual(operation.busyReplies, 1)
        XCTAssertEqual(operation.restarts, 1)
        XCTAssertEqual(operation.received, 20)
        XCTAssertEqual(operation.phase, .completed)
    }

    func testNetworkTimeoutRetainsFailedStageAndBytes() {
        let operation = ReaderDownloadOperation(size: 20) { _ in }
        operation.note(.request); operation.note(.received(10)); operation.note(.request)
        operation.finish(.failure(URLError(.timedOut)), phase: .failed)
        XCTAssertEqual(operation.failurePhase, .fetching)
        XCTAssertEqual(operation.errorCode, URLError.timedOut.rawValue)
        XCTAssertEqual(operation.received, 10)
        operation.drained()
        XCTAssertEqual(operation.phase, .failed)
    }

    func testRejectedDownloadAlwaysCompletes() throws {
        let name = "Pocket.download-rejection." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = PocketModel(sessionStorage: ReaderSessionStorage(root: folder, defaults: defaults))
        defer { model.pauseForBackground() }
        var callbacks = 0
        model.downloadFromReader(path: "/unused.epub", size: 20, document: nil) { result in
            callbacks += 1
            guard case .failure(let error) = result else { return XCTFail("Unexpected success") }
            XCTAssertEqual(error as? ReaderDownloadError, .unavailable)
        }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(model.readerDownloadOperation?.phase, .rejected)
    }
}
