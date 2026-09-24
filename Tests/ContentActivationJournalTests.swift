import XCTest
@testable import Pocket

final class ContentActivationJournalTests: XCTestCase {
    private func location() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("activation.json")
    }

    private func pending() -> PendingContentActivation {
        .init(id: UUID(), deviceID: "1234ABCD", revision: String(repeating: "a", count: 64),
              previousGeneration: 7, capabilities: 3)
    }

    func testRestartPreservesIntentAndOnlyMatchingCompletionClearsIt() async throws {
        let file = try location()
        let store = ContentActivationJournal(file: file)
        let intent = pending()
        try await store.begin(intent)
        try await store.begin(intent)
        let bytes = try Data(contentsOf: file)
        let reopened = ContentActivationJournal(file: file)
        let restored = try await reopened.load()
        XCTAssertEqual(restored, intent)
        do { try await reopened.complete(pending()); XCTFail("Wrong transaction") } catch { }
        do { try await reopened.begin(pending()); XCTFail("Unresolved transaction") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try await reopened.complete(intent)
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }

    func testMalformedOversizedAndUnknownRecordsAreNotReplaced() async throws {
        let file = try location()
        let store = ContentActivationJournal(file: file)
        for bytes in [Data("broken".utf8), Data(repeating: 0, count: 4097), Data("{\"schema\":2}".utf8)] {
            try bytes.write(to: file)
            do { try await store.begin(pending()); XCTFail("Must preserve invalid record") } catch { }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testExplicitUnreadableRecoveryPreservesBytesAndRefusesValidOrMissingRecords() async throws {
        let file = try location()
        let store = ContentActivationJournal(file: file)
        do { _ = try await store.recoverUnreadableRecord(); XCTFail("Absent is not corrupt") } catch { }
        for bytes in [Data("broken JSON".utf8), Data(repeating: 0xFF, count: 4097), Data("{\"schema\":2}".utf8)] {
            try bytes.write(to: file, options: .atomic)
            let backup = try await store.recoverUnreadableRecord()
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            let cleared = try await store.load()
            XCTAssertNil(cleared)
        }
        let intent = pending()
        try await store.begin(intent)
        let original = try Data(contentsOf: file)
        do { _ = try await store.recoverUnreadableRecord(); XCTFail("Valid intent must not be discarded") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testModelUnreadableRecoveryIsExplicitLocalAndDisabledInDemo() async throws {
        let file = try location()
        let original = Data("invalid tracking".utf8)
        try original.write(to: file)
        let model = PocketModel(activationJournal: ContentActivationJournal(file: file))
        await model.restorePendingContentActivation()
        XCTAssertNotNil(model.activationRecordError)
        XCTAssertEqual(try Data(contentsOf: file), original)
        model.isDemoMode = true
        await model.recoverContentActivationRecord()
        XCTAssertEqual(try Data(contentsOf: file), original)
        model.isDemoMode = false
        await model.recoverContentActivationRecord()
        XCTAssertNil(model.activationRecordError)
        XCTAssertNil(model.contentDeployment)
        XCTAssertNil(model.readerStatus)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(model.activationRecordBackup)), original)
    }

    func testUnreadableRecoveryDoesNotFollowSymlinksOrReplaceDirectory() async throws {
        let file = try location()
        let source = file.deletingLastPathComponent().appendingPathComponent("source.json")
        let bytes = Data("broken source".utf8)
        try bytes.write(to: source)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        do {
            _ = try await ContentActivationJournal(file: file).recoverUnreadableRecord()
            XCTFail("Do not recover over symlink")
        } catch { XCTAssertEqual(try Data(contentsOf: source), bytes) }
        let directory = file.deletingLastPathComponent()
        do {
            _ = try await ContentActivationJournal(file: directory).recoverUnreadableRecord()
            XCTFail("Do not recover over directory")
        } catch {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType,
                           .typeDirectory)
        }
    }

    func testArchivePreservesExactBytesAndAllowsANewIntentWithoutDeletingHistory() async throws {
        let file = try location()
        let store = ContentActivationJournal(file: file)
        let intent = pending()
        try await store.begin(intent)
        let original = try Data(contentsOf: file)
        let archive = try await store.archive(intent)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let cleared = try await store.load()
        XCTAssertNil(cleared)
        let next = pending()
        try await store.begin(next)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let nextBytes = try Data(contentsOf: file)
        do { _ = try await store.archive(intent); XCTFail("Cannot archive another operation") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), nextBytes)
        let restored = try await ContentActivationJournal(file: file).load()
        XCTAssertEqual(restored, next)
    }

    @MainActor
    func testOfflineModelArchivesOnlyAfterExplicitCallAndDemoCannotArchive() async throws {
        let file = try location()
        let store = ContentActivationJournal(file: file)
        let intent = pending()
        try await store.begin(intent)
        let model = PocketModel(activationJournal: store)
        await model.restorePendingContentActivation()
        model.isDemoMode = true
        await model.archivePendingContentActivation()
        let stillPending = try await store.load()
        XCTAssertEqual(stillPending, intent)
        model.isDemoMode = false
        await model.archivePendingContentActivation()
        XCTAssertEqual(model.contentDeployment?.phase, .archived)
        XCTAssertNotNil(model.contentDeployment?.archivedRecord)
        XCTAssertNil(model.readerStatus)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isTransferring)
        let cleared = try await store.load()
        XCTAssertNil(cleared)
        XCTAssertTrue(model.message.contains("may still have applied"))
    }

    @MainActor
    func testArchiveFailureKeepsUnknownOutcomeAndDoesNotClearDifferentIntent() async throws {
        let store = ContentActivationJournal(file: try location())
        let original = pending()
        try await store.begin(original)
        let deployment = ContentDeployment(restoring: original, journal: store)
        try await store.complete(original)
        let newer = pending()
        try await store.begin(newer)
        do { try await deployment.archivePendingActivation(); XCTFail("Stale operation") } catch { }
        XCTAssertEqual(deployment.phase, .needsConfirmation)
        XCTAssertNil(deployment.archivedRecord)
        let retained = try await store.load()
        XCTAssertEqual(retained, newer)
    }

    @MainActor
    func testRestoredIntentConfirmsReadOnlyAndClearsDurableRecord() async throws {
        let store = ContentActivationJournal(file: try location())
        let intent = pending()
        try await store.begin(intent)
        let loaded = try await store.load()
        let restored = try XCTUnwrap(loaded)
        let deployment = ContentDeployment(restoring: restored, journal: store)
        XCTAssertEqual(deployment.phase, .needsConfirmation)
        let receipt = try await deployment.confirmPendingActivation {
            .init(deviceID: intent.deviceID, schema: 1, capabilities: 3,
                  active: .init(revision: intent.revision, generation: 8))
        }
        XCTAssertEqual(receipt.generation, 8)
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }

    @MainActor
    func testModelRestoresLocallyButDemoDoesNotLoadOrClearPendingIntent() async throws {
        let store = ContentActivationJournal(file: try location())
        let intent = pending()
        try await store.begin(intent)
        let model = PocketModel(activationJournal: store)
        model.isDemoMode = true
        await model.restorePendingContentActivation()
        XCTAssertNil(model.contentDeployment)
        model.isDemoMode = false
        await model.restorePendingContentActivation()
        XCTAssertEqual(model.contentDeployment?.phase, .needsConfirmation)
        XCTAssertNil(model.readerStatus)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isTransferring)
        model.confirmContentActivation() // No selected reader: admission only.
        XCTAssertFalse(model.isWorking)
        let retained = try await store.load()
        XCTAssertEqual(retained, intent)
    }
}
