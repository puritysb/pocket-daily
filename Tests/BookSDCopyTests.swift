import XCTest
@testable import Pocket

@MainActor
final class BookSDCopyTests: XCTestCase {
    private var roots: [URL] = []
    private var models: [PocketModel] = []

    override func tearDown() {
        for model in models {
            model.pauseForBackground()
            for copy in model.preparedTransfers where copy.bookJobID != nil {
                try? FileManager.default.removeItem(at: TransferPreparation.file(copy).deletingLastPathComponent())
            }
        }
        for root in roots { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func wait(_ model: PocketModel) async throws {
        for _ in 0..<300 where model.isWorking || model.bookTransferJobsLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.bookTransferJobsLoading)
    }

    private func setup(count: Int = 1, operations: PocketModel.LocalFileOperations = .init(),
                       store: BookTransferJobStore? = nil) async throws -> (PocketModel, LibraryModel, [LibraryBook], UUID, BookTransferJobStore) {
        let root = try folder()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "library.welcome.v1")
        let storage = BookLibrary(root: root.appendingPathComponent("library"))
        var books: [LibraryBook] = []
        for index in 0..<count {
            let document = BookLibrary.document(title: "Selected \(index)", text: "Original selected bytes \(index)", markdown: false)
            books.append(try await storage.importDocument(document, origin: .written))
        }
        let library = LibraryModel(storage: storage, defaults: defaults)
        await library.load()
        let selectedStore = store ?? BookTransferJobStore(file: root.appendingPathComponent("jobs.json"))
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), localFiles: operations, bookTransferStore: selectedStore)
        models.append(model)
        let created = await model.createBookTransferJob(books: books, library: library)
        let id = try XCTUnwrap(created)
        try await wait(model)
        return (model, library, books, id, selectedStore)
    }

    func testSelectedBytesAreCopiedAtomicallyAndExistingFileIsNeverOverwritten() async throws {
        let (model, library, books, id, store) = try await setup()
        let root = try folder()
        let original = try await library.fileURL(for: books[0])
        let beforeWireless = try XCTUnwrap(model.bookTransferJob(id))
        model.copyBookTransferJobToSD(id, root: root, library: library)
        try await wait(model)
        let output = root.appendingPathComponent(original.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: original))
        let copied = try XCTUnwrap(model.bookTransferJob(id))
        XCTAssertEqual(copied.latestSDCopy?.stage, .completed)
        XCTAssertEqual(copied.latestSDCopy?.items.first?.result, .copied)
        XCTAssertEqual(copied.items, beforeWireless.items)
        XCTAssertEqual(copied.stage, beforeWireless.stage)
        XCTAssertFalse(copied.requiresAttention, "An SD completion must not keep emphasizing the unused Wi-Fi stage")
        XCTAssertEqual(copied.presentationStatus, "Books copied to SD card")
        let persisted = try await store.load()
        XCTAssertEqual(persisted.first?.latestSDCopy?.items.first?.result, .copied)
        model.copyBookTransferJobToSD(id, root: root, library: library)
        try await wait(model)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.stage, .completed, "Explicitly reselecting a folder verifies prior bytes without rewriting them")
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: original))
        XCTAssertEqual(model.bookTransferJob(id)?.sdCopies?.count, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("pocket-staging") })
    }

    func testSDCompletionPreservesUnknownWiFiResultAndItsOriginalTarget() async throws {
        let (model, library, books, id, store) = try await setup()
        var job = try XCTUnwrap(model.bookTransferJob(id))
        let transferID = try XCTUnwrap(job.items.first?.transferID)
        var prepared = try XCTUnwrap(model.preparedTransfers.first { $0.id == transferID })
        prepared.publicationPending = true
        prepared.readerID = "ABCD1234"
        prepared.remoteStagingID = prepared.id
        try JSONEncoder().encode(prepared).write(to: TransferPreparation.file(prepared).deletingLastPathComponent().appendingPathComponent("transfer.json"), options: .atomic)
        job.items[0].result = .confirmationUnknown
        job.stage = .confirmationUnknown
        job.target = .init(readerID: "ABCD1234", displayName: "Original X3")
        try await store.save([job])
        model.pauseForBackground()
        let restarted = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), bookTransferStore: store)
        models.append(restarted)
        try await wait(restarted)
        let root = try folder()
        restarted.copyBookTransferJobToSD(id, root: root, library: library)
        try await wait(restarted)
        let result = try XCTUnwrap(restarted.bookTransferJob(id))
        XCTAssertEqual(result.latestSDCopy?.stage, .completed)
        XCTAssertEqual(result.items[0].result, .confirmationUnknown)
        XCTAssertEqual(result.stage, .confirmationUnknown)
        XCTAssertEqual(result.target, job.target)
        XCTAssertTrue(result.requiresAttention)
        XCTAssertFalse(restarted.canSendBookTransferJob(id))
        XCTAssertEqual(result.items.first?.bookID, books.first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TransferPreparation.file(prepared).path))
    }

    func testPartialFailureRecordsOnlyConfirmedCopiesAndPreservesCollision() async throws {
        let (model, library, books, id, _) = try await setup(count: 2)
        let root = try folder()
        let second = try await library.fileURL(for: books[1])
        let existing = Data("existing book must stay".utf8)
        try existing.write(to: root.appendingPathComponent(second.lastPathComponent))
        model.copyBookTransferJobToSD(id, root: root, library: library)
        try await wait(model)
        let result = try XCTUnwrap(model.bookTransferJob(id)?.latestSDCopy)
        XCTAssertEqual(result.stage, .partialCompletion)
        XCTAssertEqual(result.items.map(\.result), [.copied, .failed])
        XCTAssertNotNil(result.items[1].failure)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(second.lastPathComponent)), existing)
    }

    func testPauseDrainsNonCooperativeCopyAndDuplicateSubmitCannotStartSecondBatch() async throws {
        let gate = SDCopyGate()
        let operations = PocketModel.LocalFileOperations(copy: { source, root in
            await gate.wait()
            return try await Task.detached { try PocketModel.copyToSDOffMain(source: source, root: root) }.value
        })
        let (model, library, _, id, _) = try await setup(count: 2, operations: operations)
        let root = try folder()
        model.copyBookTransferJobToSD(id, root: root, library: library)
        model.copyBookTransferJobToSD(id, root: root, library: library)
        for _ in 0..<300 {
            if await gate.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.activeReaderTask, .bookTransfer(id))
        let changed = await model.selectBookTransferDestination(id, destination: .readerWiFi)
        XCTAssertFalse(changed)
        model.pauseBookTransferJob(id)
        XCTAssertTrue(model.isWorking, "Keep the lane owned until the copy drains")
        await gate.release()
        try await wait(model)
        let count = await gate.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.bookTransferJob(id)?.sdCopies?.count, 1)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.stage, .paused)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.copiedCount, 1)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.items.last?.result, .waiting)
        XCTAssertNil(model.activeReaderTask)
    }

    func testSaveFailureAfterSDPublicationRestoresUncertaintyWithoutAutomaticCopy() async throws {
        let root = try folder()
        let fault = SDRecordWriteFailure()
        let file = root.appendingPathComponent("jobs.json")
        let store = BookTransferJobStore(file: file, write: { data, url in try fault.write(data, to: url) })
        let operations = PocketModel.LocalFileOperations(copy: { source, root in
            let result = try await Task.detached { try PocketModel.copyToSDOffMain(source: source, root: root) }.value
            fault.setFailing(true)
            return result
        })
        let (model, library, books, id, _) = try await setup(operations: operations, store: store)
        let target = try folder()
        model.copyBookTransferJobToSD(id, root: target, library: library)
        try await wait(model)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.stage, .confirmationUnknown)
        XCTAssertNotNil(model.bookTransferError)
        let original = try await library.fileURL(for: books[0])
        let output = target.appendingPathComponent(original.lastPathComponent)
        let copiedBytes = try Data(contentsOf: output)
        XCTAssertEqual(copiedBytes, try Data(contentsOf: original))
        fault.setFailing(false)
        model.pauseForBackground()
        let restarted = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), bookTransferStore: store)
        models.append(restarted)
        try await wait(restarted)
        XCTAssertEqual(restarted.bookTransferJob(id)?.latestSDCopy?.stage, .confirmationUnknown)
        XCTAssertFalse(restarted.isWorking)
        XCTAssertEqual(try Data(contentsOf: output), copiedBytes)
        let archived = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(archived.contains(target.path), "No directory access URL or bookmark is persisted")
        restarted.copyBookTransferJobToSD(id, root: target, library: library)
        try await wait(restarted)
        XCTAssertEqual(restarted.bookTransferJob(id)?.latestSDCopy?.stage, .completed)
        XCTAssertEqual(try Data(contentsOf: output), copiedBytes)
    }

    func testMissingOriginalAndInvalidDestinationFailWithoutMutatingLibrary() async throws {
        let (model, library, books, id, _) = try await setup()
        let source = try await library.fileURL(for: books[0])
        let original = try Data(contentsOf: source)
        let target = try folder().appendingPathComponent("not-a-directory")
        try Data("keep this".utf8).write(to: target)
        model.copyBookTransferJobToSD(id, root: target, library: library)
        try await wait(model)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.stage, .failed)
        XCTAssertEqual(try Data(contentsOf: source), original)
        await library.remove(books[0])
        let folder = try folder()
        model.copyBookTransferJobToSD(id, root: folder, library: library)
        try await wait(model)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.items.first?.result, .failed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testAccessDeniedDoesNotClaimCopyAndKeepsOriginalBytes() async throws {
        let operations = PocketModel.LocalFileOperations(copy: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let (model, library, books, id, _) = try await setup(operations: operations)
        let original = try await library.fileURL(for: books[0])
        let bytes = try Data(contentsOf: original)
        let target = try folder()
        model.copyBookTransferJobToSD(id, root: target, library: library)
        try await wait(model)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.stage, .failed)
        XCTAssertEqual(model.bookTransferJob(id)?.latestSDCopy?.copiedCount, 0)
        XCTAssertNotNil(model.bookTransferJob(id)?.latestSDCopy?.items.first?.failure)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testDemoNeverCopiesAndRestoredResultsRequireDirectoryReselection() async throws {
        let (model, library, books, id, store) = try await setup()
        let target = try folder()
        model.copyBookTransferJobToSD(id, root: target, library: library)
        try await wait(model)
        model.pauseForBackground()
        let restarted = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), bookTransferStore: store)
        models.append(restarted)
        try await wait(restarted)
        XCTAssertEqual(restarted.bookTransferJob(id)?.latestSDCopy?.stage, .completed)
        XCTAssertFalse(restarted.isWorking)
        restarted.enterDemoMode()
        let created = await restarted.createBookTransferJob(books: books, library: library)
        let demoID = try XCTUnwrap(created)
        let untouched = try folder()
        restarted.copyBookTransferJobToSD(demoID, root: untouched, library: library)
        XCTAssertNil(restarted.bookTransferJob(demoID)?.latestSDCopy)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: untouched.path).isEmpty)
    }

    func testDiscardedJobCannotChangeDestinationOrStartSDCopy() async throws {
        let (model, library, _, id, _) = try await setup()
        model.discardBookTransferJob(id)
        try await wait(model)
        XCTAssertEqual(model.bookTransferJob(id)?.stage, .discarded)
        let changed = await model.selectBookTransferDestination(id, destination: .sdCard)
        XCTAssertFalse(changed)
        let target = try folder()
        model.copyBookTransferJobToSD(id, root: target, library: library)
        XCTAssertNil(model.bookTransferJob(id)?.latestSDCopy)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testReconnectOriginalReaderClosesWrongSessionAndNeverChangesSelectionOrSends() async throws {
        let (model, _, _, id, _) = try await setup()
        let target = BookTransferTarget(readerID: "ABCD1234", displayName: "Original X3")
        let selected = await model.selectBookTransferTarget(id, target: target)
        XCTAssertTrue(selected)
        let selection = model.bookTransferJob(id)?.items
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(#"{"version":"test","device":"X4","deviceID":"9999FFFF","ip":"192.0.2.1","mode":"STA","rssi":-40,"freeHeap":20000,"uptime":1,"transferControl":1}"#.utf8))
        let readyForConnection = await model.disconnectForBookTransferRecovery(id)
        XCTAssertTrue(readyForConnection)
        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(model.bookTransferJob(id)?.target, target)
        XCTAssertEqual(model.bookTransferJob(id)?.items, selection)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isTransferring)
        XCTAssertNil(model.activeReaderTask)
    }
}

private actor SDCopyGate {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        count += 1
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class SDRecordWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    func write(_ data: Data, to url: URL) throws {
        if lock.withLock({ failing }) { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}
