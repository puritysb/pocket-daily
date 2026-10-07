import XCTest
@testable import Pocket

@MainActor
final class BookTransferJobTests: XCTestCase {
    private var folders: [URL] = []
    private let bytes = Data("selected book bytes".utf8)

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fixture(_ filename: String, jobID: UUID? = nil, bookID: UUID? = nil,
                         pending: Bool = false) throws -> PreparedTransfer {
        let item = PreparedTransfer(id: UUID(), filename: filename, firmwareVersion: nil,
                                    readerID: pending ? "ABCD1234" : nil,
                                    remoteStagingID: pending ? UUID() : nil,
                                    publicationPending: pending,
                                    bookJobID: jobID, libraryBookID: bookID)
        let folder = TransferPreparation.file(item).deletingLastPathComponent()
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: TransferPreparation.file(item))
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("transfer.json"), options: .atomic)
        return item
    }

    private func job(_ transfer: PreparedTransfer, id: UUID, bookID: UUID,
                     result: BookTransferJob.Result = .prepared) -> BookTransferJob {
        BookTransferJob(id: id, target: .init(readerID: "ABCD1234", displayName: "X3"),
                        origin: .init(search: "retained", collection: "Books", focusedBookID: bookID),
                        stage: .ready, items: [.init(bookID: bookID, title: "Selected", transferID: transfer.id, result: result)])
    }

    private func setup(jobs: [BookTransferJob] = [], corrupt: Bool = false, missingManifest: Bool = false,
                       localFiles: PocketModel.LocalFileOperations = .init()) async throws -> (PocketModel, BookTransferJobStore, URLSession) {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("jobs.json")
        let store = BookTransferJobStore(file: file)
        if corrupt { try Data("invalid archive".utf8).write(to: file) }
        else if !missingManifest { try await store.save(jobs) }
        BookJobProtocol.reset(bytes: bytes)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BookJobProtocol.self]
        let session = URLSession(configuration: config)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session), localFiles: localFiles, bookTransferStore: store)
        for _ in 0..<300 where model.bookTransferJobsLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.bookTransferJobsLoading)
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: BookJobProtocol.status())
        return (model, store, session)
    }

    private func wait(_ model: PocketModel) async throws {
        for _ in 0..<300 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isWorking)
    }

    func testExactJobScopeExcludesOldBookAndFirmwareAndDuplicateSend() async throws {
        let id = UUID(), bookID = UUID()
        let selected = try fixture("chosen.epub", jobID: id, bookID: bookID)
        let oldBook = try fixture("older.epub")
        let firmware = try fixture("update.bin")
        let (model, _, session) = try await setup(jobs: [job(selected, id: id, bookID: bookID)])
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        model.sendBookTransferJob(id)
        model.sendBookTransferJob(id)
        try await wait(model)
        XCTAssertEqual(BookJobProtocol.controls.count, 1)
        XCTAssertEqual(BookJobProtocol.controls.first?["staging"], "/.pocket-\(selected.id.uuidString.lowercased()).part")
        XCTAssertNil(model.preparedTransfers.first { $0.id == oldBook.id }?.stagingID)
        XCTAssertNil(model.preparedTransfers.first { $0.id == firmware.id }?.stagingID)
        XCTAssertEqual(model.bookTransferJob(id)?.origin.search, "retained")
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .failed)
    }

    func testReceiptRecoveryPersistsCompletionBeforeDeletingCopyAndSurvivesRestart() async throws {
        let id = UUID(), bookID = UUID()
        let selected = try fixture("receipt.epub", jobID: id, bookID: bookID, pending: true)
        let (model, store, session) = try await setup(jobs: [job(selected, id: id, bookID: bookID, result: .sending)])
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .confirmationUnknown)
        XCTAssertFalse(model.canSendBookTransferJob(id))
        XCTAssertTrue(BookJobProtocol.paths.isEmpty, "Restart must not start a request")
        model.checkBookTransferJob(id)
        try await wait(model)
        XCTAssertTrue(BookJobProtocol.controls.isEmpty)
        XCTAssertFalse(BookJobProtocol.paths.contains("/upload"))
        XCTAssertFalse(BookJobProtocol.paths.contains("/api/pocket/v1/commit"))
        XCTAssertTrue(BookJobProtocol.paths.contains("/api/pocket/v1/publication"))
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .completed)
        XCTAssertEqual(model.bookTransferJob(id)?.items.first?.result, .saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TransferPreparation.file(selected).path))
        let persisted = try await store.load()
        XCTAssertEqual(persisted.first?.items.first?.result, .saved)
        XCTAssertNotNil(persisted.first?.items.first?.publishedPath)
        let restarted = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), bookTransferStore: store)
        for _ in 0..<300 where restarted.bookTransferJobsLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(restarted.bookTransferJob(id)?.stage, .completed)
        restarted.pauseForBackground()
    }

    func testCorruptReceiptNeverBlindlyRetriesOrDiscardsUnknownPublication() async throws {
        let id = UUID(), bookID = UUID()
        let selected = try fixture("unknown.epub", jobID: id, bookID: bookID, pending: true)
        let (model, _, session) = try await setup(jobs: [job(selected, id: id, bookID: bookID)])
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        BookJobProtocol.corruptReceipt()
        model.checkBookTransferJob(id)
        try await wait(model)
        model.sendBookTransferJob(id)
        model.discardBookTransferJob(id)
        try await wait(model)
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .confirmationUnknown)
        XCTAssertNotNil(model.bookTransferJob(id)?.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TransferPreparation.file(selected).path))
        XCTAssertTrue(BookJobProtocol.controls.isEmpty)
        XCTAssertFalse(BookJobProtocol.paths.contains("/upload"))
        XCTAssertFalse(BookJobProtocol.paths.contains("/api/pocket/v1/commit"))
    }

    func testPartialCompletionRetriesOnlyRemainingBook() async throws {
        let id = UUID(), savedBookID = UUID(), remainingBookID = UUID()
        let remaining = try fixture("remaining.epub", jobID: id, bookID: remainingBookID)
        var value = job(remaining, id: id, bookID: remainingBookID)
        value.items.insert(.init(bookID: savedBookID, title: "Already saved", transferID: UUID(), result: .saved, publishedPath: "/saved.epub"), at: 0)
        let (model, store, session) = try await setup(jobs: [value])
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .partialCompletion)
        model.sendBookTransferJob(id)
        try await wait(model)
        XCTAssertEqual(BookJobProtocol.controls.count, 1)
        XCTAssertEqual(BookJobProtocol.controls.first?["staging"], "/.pocket-\(remaining.id.uuidString.lowercased()).part")
        XCTAssertEqual(model.bookTransferJob(id)?.items.first?.result, .saved)
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .partialCompletion)
        let persisted = try await store.load()
        XCTAssertEqual(persisted.first?.savedCount, 1)
    }

    func testMissingCopyRecoversUnknownAndNeverReprepares() async throws {
        let id = UUID(), bookID = UUID()
        let selected = PreparedTransfer(id: UUID(), filename: "missing.epub", firmwareVersion: nil)
        let (model, _, session) = try await setup(jobs: [job(selected, id: id, bookID: bookID)])
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .confirmationUnknown)
        model.checkBookTransferJob(id)
        XCTAssertTrue(BookJobProtocol.paths.isEmpty)
        XCTAssertNotNil(model.bookTransferJob(id)?.failure)
        XCTAssertFalse(model.canSendBookTransferJob(id))
    }

    func testLegacyQueueCannotAdoptOwnedCopiesWhenManifestIsCorrupt() async throws {
        let owned = try fixture("owned.epub", jobID: UUID(), bookID: UUID())
        let old = try fixture("legacy.epub")
        let (model, _, session) = try await setup(corrupt: true)
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertNotNil(model.bookTransferError)
        model.sendPreparedFiles()
        try await wait(model)
        XCTAssertEqual(BookJobProtocol.controls.count, 1)
        XCTAssertEqual(BookJobProtocol.controls.first?["staging"], "/.pocket-\(old.id.uuidString.lowercased()).part")
        XCTAssertNil(model.preparedTransfers.first { $0.id == owned.id }?.stagingID)
        model.removePreparedFiles(localOnly: true)
        try await wait(model)
        XCTAssertNotNil(model.preparedTransfers.first { $0.id == owned.id })
        XCTAssertNil(model.preparedTransfers.first { $0.id == old.id })
    }

    func testChangedTargetAndWrongJobPauseCannotTouchActiveLane() async throws {
        let id = UUID(), bookID = UUID()
        let selected = try fixture("target.epub", jobID: id, bookID: bookID)
        let (model, _, session) = try await setup(jobs: [job(selected, id: id, bookID: bookID)])
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        var otherStatus = try XCTUnwrap(model.readerStatus)
        otherStatus.deviceID = "9999FFFF"
        model.readerStatus = otherStatus
        XCTAssertFalse(model.canSendBookTransferJob(id))
        model.sendBookTransferJob(id)
        XCTAssertTrue(BookJobProtocol.paths.isEmpty)
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: BookJobProtocol.status())
        BookJobProtocol.holdPrepare()
        model.sendBookTransferJob(id)
        for _ in 0..<300 where BookJobProtocol.controls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        model.pauseBookTransferJob(UUID())
        XCTAssertTrue(model.isWorking)
        model.stopAndRemoveTransfer() // Legacy Stop cannot cancel this job.
        XCTAssertTrue(model.isWorking)
        model.pauseTransfer() // The older queue's Pause cannot cancel it either.
        XCTAssertTrue(model.isWorking)
        model.pauseBookTransferJob(id)
        try await wait(model)
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .paused)
        XCTAssertNotNil(model.preparedTransfers.first { $0.id == selected.id })
        XCTAssertEqual(BookJobProtocol.controls.count, 1)
    }

    func testCreationReturnsPreparingJobImmediatelyAndReopeningNeverDuplicatesCopy() async throws {
        let root = try temporaryFolder()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "library.welcome.v1")
        let storage = BookLibrary(root: root)
        let book = try await storage.importDocument(WelcomeBook.document, origin: .written)
        let library = LibraryModel(storage: storage, defaults: defaults)
        await library.load()
        let gate = BookPreparationGate()
        let operations = PocketModel.LocalFileOperations(prepareBook: { url, id, jobID, bookID in
            await gate.wait()
            return try await Task.detached { try TransferPreparation.prepare(url, id: id, bookJobID: jobID, libraryBookID: bookID) }.value
        })
        let (model, store, session) = try await setup(localFiles: operations)
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        let first = await model.createBookTransferJob(books: [book], library: library, origin: .init(search: "original search"))
        let id = try XCTUnwrap(first)
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .preparing)
        XCTAssertTrue(model.isWorking)
        let reopened = await model.createBookTransferJob(books: [book], library: library)
        XCTAssertEqual(reopened, id)
        XCTAssertEqual(model.bookTransferJobs.count, 1)
        for _ in 0..<300 {
            if await gate.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.pauseBookTransferJob(id)
        await gate.release()
        try await wait(model)
        let count = await gate.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .paused)
        let transferID = try XCTUnwrap(model.bookTransferJob(id)?.items.first?.transferID)
        let transfer = try XCTUnwrap(model.preparedTransfers.first { $0.id == transferID })
        folders.append(TransferPreparation.file(transfer).deletingLastPathComponent())
        XCTAssertEqual(transfer.bookJobID, id)
        XCTAssertEqual(transfer.libraryBookID, book.id)
        let source = try await library.fileURL(for: book)
        XCTAssertEqual(try Data(contentsOf: TransferPreparation.file(transfer)), try Data(contentsOf: source))
        let persisted = try await store.load()
        XCTAssertEqual(persisted.first?.items.first?.transferID, transferID)
        XCTAssertTrue(BookJobProtocol.paths.isEmpty, "Preparation and cancellation never send bytes")
    }

    func testUnidentifiedRestoredTargetRequiresExplicitSelectionAndUnsupportedReaderCannotSend() async throws {
        let id = UUID(), bookID = UUID()
        let selected = try fixture("unidentified.epub", jobID: id, bookID: bookID)
        var value = job(selected, id: id, bookID: bookID)
        value.target = .init(readerID: nil, displayName: "X3")
        let (model, _, session) = try await setup(jobs: [value])
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        var status = try XCTUnwrap(model.readerStatus)
        status.deviceID = nil
        model.readerStatus = status
        XCTAssertFalse(model.canSendBookTransferJob(id), "Remembered model cannot prove the same unidentified reader")
        let chosen = await model.selectBookTransferTarget(id, target: .init(readerID: nil, displayName: "X3"))
        XCTAssertTrue(chosen)
        XCTAssertTrue(model.canSendBookTransferJob(id))
        status.transferControl = nil
        model.readerStatus = status
        XCTAssertFalse(model.canSendBookTransferJob(id))
        model.sendBookTransferJob(id)
        XCTAssertTrue(BookJobProtocol.paths.isEmpty)
    }

    func testPreparationFailureRequiresRemainingCopiesAndRetryNeverSends() async throws {
        let root = try temporaryFolder()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "library.welcome.v1")
        let storage = BookLibrary(root: root)
        let book = try await storage.importDocument(WelcomeBook.document, origin: .written)
        let library = LibraryModel(storage: storage, defaults: defaults)
        await library.load()
        let gate = FailingBookPreparation()
        let operations = PocketModel.LocalFileOperations(prepareBook: { url, id, jobID, bookID in
            if await gate.shouldFail() { throw LibraryError.unavailable }
            return try await Task.detached { try TransferPreparation.prepare(url, id: id, bookJobID: jobID, libraryBookID: bookID) }.value
        })
        let (model, _, session) = try await setup(localFiles: operations)
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        let created = await model.createBookTransferJob(books: [book], library: library)
        let id = try XCTUnwrap(created)
        try await wait(model)
        XCTAssertFalse(model.canSendBookTransferJob(id))
        XCTAssertEqual(model.bookTransferJob(id)?.items.first?.result, .failed)
        await model.retryBookTransferJob(id, library: library)
        try await wait(model)
        XCTAssertTrue(model.canSendBookTransferJob(id))
        XCTAssertTrue(BookJobProtocol.paths.isEmpty, "Retry preparation still waits for explicit Send")
        let transferID = try XCTUnwrap(model.bookTransferJob(id)?.items.first?.transferID)
        let transfer = try XCTUnwrap(model.preparedTransfers.first { $0.id == transferID })
        folders.append(TransferPreparation.file(transfer).deletingLastPathComponent())
        let firstRecord = try JSONDecoder().decode(PreparedTransfer.self, from: Data(contentsOf: TransferPreparation.file(transfer).deletingLastPathComponent().appendingPathComponent("transfer.json")))
        XCTAssertEqual(firstRecord.bookJobID, id)
        XCTAssertEqual(firstRecord.libraryBookID, book.id)
    }

    func testCorruptJobReferenceCannotSendCheckOrForgetUnrelatedPreparedFile() async throws {
        let unrelated = try fixture("unrelated.epub")
        let id = UUID(), bookID = UUID()
        let (model, _, session) = try await setup(jobs: [job(unrelated, id: id, bookID: bookID)])
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .confirmationUnknown)
        XCTAssertFalse(model.canSendBookTransferJob(id))
        model.checkBookTransferJob(id)
        XCTAssertTrue(BookJobProtocol.paths.isEmpty)
        model.discardBookTransferJob(id, localOnly: true)
        try await wait(model)
        XCTAssertNotNil(model.preparedTransfers.first { $0.id == unrelated.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: TransferPreparation.file(unrelated).path))
    }

    func testDemoStartupDoesNotRecoverOrRewriteRealTransferRecord() async throws {
        let id = UUID(), bookID = UUID()
        let selected = try fixture("real-pending.epub", jobID: id, bookID: bookID, pending: true)
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("jobs.json")
        let store = BookTransferJobStore(file: file)
        try await store.save([job(selected, id: id, bookID: bookID, result: .sending)])
        let before = try Data(contentsOf: file)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), bookTransferStore: store)
        model.enterDemoMode()
        for _ in 0..<300 where model.bookTransferJobsLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isDemoMode)
        XCTAssertTrue(model.bookTransferJobs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TransferPreparation.file(selected).path))
        model.exitDemoMode()
        for _ in 0..<300 where model.bookTransferJobsLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .confirmationUnknown)
        model.pauseForBackground()
    }

    func testLostManifestRestoresOwnedJobAndSameBookCannotBypassUncertainReceipt() async throws {
        let root = try temporaryFolder()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "library.welcome.v1")
        let storage = BookLibrary(root: root)
        let book = try await storage.importDocument(WelcomeBook.document, origin: .written)
        let library = LibraryModel(storage: storage, defaults: defaults)
        await library.load()
        let id = UUID()
        let selected = try fixture("owned-orphan.epub", jobID: id, bookID: book.id, pending: true)
        let (model, store, session) = try await setup(missingManifest: true)
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .confirmationUnknown)
        XCTAssertEqual(model.bookTransferJob(id)?.items.first?.transferID, selected.id)
        XCTAssertEqual(model.bookTransferJob(id)?.target?.readerID, "ABCD1234")
        let reopened = await model.createBookTransferJob(books: [book], library: library)
        XCTAssertEqual(reopened, id)
        XCTAssertEqual(model.bookTransferJobs.count, 1)
        XCTAssertEqual(model.preparedTransfers.filter { $0.bookJobID == id }.count, 1)
        XCTAssertFalse(model.canSendBookTransferJob(id))
        XCTAssertTrue(BookJobProtocol.paths.isEmpty)
        let persisted = try await store.load()
        XCTAssertEqual(persisted.first?.id, id)
        XCTAssertEqual(persisted.first?.items.first?.result, .confirmationUnknown)
    }

    func testConflictingOrphanOwnershipPreservesCopiesAndBlocksNewJobs() async throws {
        let id = UUID(), bookID = UUID()
        let first = try fixture("first-orphan.epub", jobID: id, bookID: bookID)
        let second = try fixture("second-orphan.epub", jobID: id, bookID: bookID)
        let (model, store, session) = try await setup()
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertNotNil(model.bookTransferError)
        XCTAssertTrue(model.bookTransferJobs.isEmpty)
        XCTAssertTrue(model.preparedTransfers.contains { $0.id == first.id })
        XCTAssertTrue(model.preparedTransfers.contains { $0.id == second.id })
        let original = try await store.load()
        XCTAssertTrue(original.isEmpty, "A recovery failure must preserve the original archive")
        model.sendPreparedFiles()
        XCTAssertTrue(BookJobProtocol.paths.isEmpty)
    }

    func testArchivedUnknownRemainsUnknownWithMissingMarkerAndDiscardedResultsStayFinal() {
        let id = UUID(), bookID = UUID()
        let copy = PreparedTransfer(id: UUID(), filename: "book.epub", firmwareVersion: nil, publicationPending: false,
                                    bookJobID: id, libraryBookID: bookID)
        var unknown = job(copy, id: id, bookID: bookID, result: .confirmationUnknown)
        unknown.recover(prepared: [copy])
        XCTAssertEqual(unknown.stage, .confirmationUnknown)
        XCTAssertEqual(unknown.items.first?.result, .confirmationUnknown)
        var discarded = job(copy, id: id, bookID: bookID, result: .discarded)
        discarded.recover(prepared: [copy])
        XCTAssertEqual(discarded.stage, .discarded)
    }

    func testOwnerMarkerRepairsInterruptedPreparationWithoutFilenameInference() {
        let id = UUID(), bookID = UUID()
        let item = PreparedTransfer(id: UUID(), filename: "any-name.epub", firmwareVersion: nil, bookJobID: id, libraryBookID: bookID)
        let unrelated = PreparedTransfer(id: UUID(), filename: "any-name.epub", firmwareVersion: nil)
        var value = BookTransferJob(id: id, origin: .init(), items: [.init(bookID: bookID, title: "Original")])
        value.recover(prepared: [unrelated, item])
        XCTAssertEqual(value.items.first?.transferID, item.id)
        XCTAssertEqual(value.items.first?.result, .prepared)
        XCTAssertEqual(value.stage, .paused)
    }
}

private final class BookJobProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedPaths: [String] = []
    nonisolated(unsafe) private static var recordedControls: [[String: String]] = []
    nonisolated(unsafe) private static var receiptBytes = Data()
    nonisolated(unsafe) private static var invalidReceipt = false
    nonisolated(unsafe) private static var heldPrepare = false
    static var paths: [String] { lock.withLock { recordedPaths } }
    static var controls: [[String: String]] { lock.withLock { recordedControls } }
    static func reset(bytes: Data) {
        lock.withLock { recordedPaths = []; recordedControls = []; receiptBytes = bytes; invalidReceipt = false; heldPrepare = false }
    }
    static func corruptReceipt() { lock.withLock { invalidReceipt = true } }
    static func holdPrepare() { lock.withLock { heldPrepare = true } }
    static func status() -> Data {
        Data(#"{"version":"test","device":"X3","deviceID":"ABCD1234","ip":"192.0.2.1","mode":"STA","rssi":-40,"freeHeap":20000,"uptime":1,"transferControl":1,"publicationReceipt":1}"#.utf8)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var sent = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                sent.append(buffer, count: count)
            }
        }
        let result = Self.lock.withLock { () -> (Data, Int, Bool) in
            Self.recordedPaths.append(url.path)
            if url.path == "/api/pocket/v1/transfer" {
                if let object = try? JSONSerialization.jsonObject(with: sent) as? [String: String] { Self.recordedControls.append(object) }
                return (Data("prepare rejected".utf8), 503, Self.heldPrepare)
            }
            if url.path == "/api/status" { return (Self.status(), 200, false) }
            let crc = Self.invalidReceipt ? "00000000" : String(format: "%08X", CRC32.checksum(Self.receiptBytes))
            return (Data("{\"size\":\(Self.receiptBytes.count),\"crc32\":\"\(crc)\"}".utf8), 200, false)
        }
        guard !result.2,
              let response = HTTPURLResponse(url: url, statusCode: result.1, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.0)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor BookPreparationGate {
    private(set) var count = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        count += 1
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FailingBookPreparation {
    private var first = true
    func shouldFail() -> Bool { defer { first = false }; return first }
}
