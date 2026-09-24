import XCTest
@testable import Pocket

final class ContentDraftStoreTests: XCTestCase {
    func testExplicitRecoveryPreservesExactInvalidBytesAndCanSaveAgain() async throws {
        let file = try location()
        let original = Data(repeating: 0xFF, count: 524289)
        try original.write(to: file)
        let store = ContentDraftStore(file: file)
        let recovered = try await store.recover(keeping: draft())
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovered.backup)), original)
        XCTAssertNotNil(recovered.saved.recoveryID)
        var edited = draft()
        edited.cards[0].title = "After recovery"
        let saved = try await store.save(edited, replacing: recovered.saved.generation,
                                         recoveryID: recovered.saved.recoveryID)
        XCTAssertEqual(saved.generation, 2)
        XCTAssertEqual(saved.draft, edited)
    }

    func testRecoveryEpochRejectsStaleEditorEvenWhenGenerationMatches() async throws {
        let store = ContentDraftStore(file: try location())
        let original = try await store.save(draft(), replacing: nil)
        let recovered = try await store.recover(keeping: .init())
        XCTAssertEqual(original.generation, recovered.saved.generation)
        do {
            _ = try await store.save(draft(), replacing: original.generation)
            XCTFail("Stale pre-recovery editor must not overwrite the recovered draft")
        } catch { XCTAssertEqual(error as? ContentDraftStore.Failure, .conflict) }
        let current = try await store.load()
        XCTAssertEqual(current, recovered.saved)
    }

    func testInvalidRecoveryAndNonFileTargetPreserveExistingData() async throws {
        let file = try location()
        let original = Data("broken draft".utf8)
        try original.write(to: file)
        let store = ContentDraftStore(file: file)
        var invalid = draft()
        invalid.cards[0].title = String(repeating: "x", count: 4097)
        do {
            _ = try await store.recover(keeping: invalid)
            XCTFail("Bounds must be checked before backup or replacement")
        } catch { XCTAssertEqual(try Data(contentsOf: file), original) }
        let directory = file.deletingLastPathComponent().appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            _ = try await ContentDraftStore(file: directory).recover(keeping: draft())
            XCTFail("Do not recover over a directory")
        } catch {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
        }
    }

    @MainActor
    func testEditorRecoversConflictWithoutLosingEitherDraft() async throws {
        let file = try location()
        let store = ContentDraftStore(file: file)
        let editor = ContentEditorModel(store: store)
        try await editor.load()
        _ = try await store.save(draft(), replacing: nil)
        var edits = draft()
        edits.cards[0].title = "My edits"
        editor.edit(edits)
        do { try await editor.save(); XCTFail("Expected conflict") } catch { }
        let previousBytes = try Data(contentsOf: file)
        try await editor.recoverKeepingEdits()
        XCTAssertEqual(editor.draft, edits)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.hasLoaded)
        XCTAssertNil(editor.lastError)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(editor.recoveryBackup)), previousBytes)
        edits.cards[0].title = "Next edit"
        editor.edit(edits)
        try await editor.save()
        let saved = try await store.load()
        XCTAssertEqual(saved?.draft, edits)
    }

    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("draft.json")
    }
    private func draft() -> ContentDraft {
        .init(cards: [.init(id: "first", title: "오늘", question: "한 줄 읽기")])
    }

    func testRoundTripAfterReopeningPreservesExactDeploymentRevision() async throws {
        let file = try location()
        let store = ContentDraftStore(file: file)
        let missing = try await store.load()
        XCTAssertNil(missing)
        let saved = try await store.save(draft(), replacing: nil)
        XCTAssertEqual(saved.generation, 1)
        let reopened = try await ContentDraftStore(file: file).load()
        XCTAssertEqual(reopened, saved)
        XCTAssertEqual(try reopened?.draft.revision().revision, try draft().revision().revision)
    }

    func testUnchangedSaveIsWriteFreeAndStaleSavePreservesNewerDraft() async throws {
        let file = try location()
        let store = ContentDraftStore(file: file)
        let first = try await store.save(draft(), replacing: nil)
        let original = try Data(contentsOf: file)
        let unchanged = try await store.save(draft(), replacing: first.generation)
        XCTAssertEqual(unchanged, first)
        XCTAssertEqual(try Data(contentsOf: file), original)
        var changed = draft()
        changed.cards[0].question = "Changed"
        let next = try await store.save(changed, replacing: first.generation)
        XCTAssertEqual(next.generation, 2)
        do {
            _ = try await store.save(draft(), replacing: first.generation)
            XCTFail("Stale editor must not replace a newer save")
        } catch { XCTAssertEqual(error as? ContentDraftStore.Failure, .conflict) }
        let loaded = try await store.load()
        XCTAssertEqual(loaded, next)
    }

    func testIncompleteTextCanBeSavedButCannotDeploy() async throws {
        let store = ContentDraftStore(file: try location())
        let unfinished = ContentDraft(cards: [.init(id: "", title: "", question: "")])
        let saved = try await store.save(unfinished, replacing: nil)
        XCTAssertEqual(saved.draft, unfinished)
        XCTAssertThrowsError(try saved.draft.revision())
    }

    func testCorruptUnknownAndOversizedFilesAreNotSilentlyReplaced() async throws {
        let file = try location()
        let store = ContentDraftStore(file: file)
        let future = ContentDraftStore.Saved(schema: 3, generation: 1, draft: draft())
        for bytes in [Data("not JSON".utf8), try JSONEncoder().encode(future), Data(repeating: 32, count: 524289)] {
            try bytes.write(to: file, options: .atomic)
            do {
                _ = try await store.save(draft(), replacing: nil)
                XCTFail("Invalid stored draft must require explicit recovery")
            } catch { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        }
    }

    func testBoundsFailurePreservesPreviousFile() async throws {
        let file = try location()
        let store = ContentDraftStore(file: file)
        let saved = try await store.save(draft(), replacing: nil)
        let original = try Data(contentsOf: file)
        var oversized = draft()
        oversized.cards[0].question = String(repeating: "가", count: 1500)
        do {
            _ = try await store.save(oversized, replacing: saved.generation)
            XCTFail("Storage bound")
        } catch { XCTAssertEqual(error as? ContentDraftStore.Failure, .bounds) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testEditorSavesReloadsAndDoesNotDiscardUnsavedChanges() async throws {
        let store = ContentDraftStore(file: try location())
        let editor = ContentEditorModel(store: store)
        try await editor.load()
        editor.edit(draft())
        XCTAssertTrue(editor.hasUnsavedChanges)
        try await editor.save()
        XCTAssertFalse(editor.hasUnsavedChanges)
        let reopened = ContentEditorModel(store: store)
        try await reopened.load()
        XCTAssertEqual(reopened.draft, draft())
        XCTAssertEqual(try reopened.deploymentSnapshot().revision, try draft().revision().revision)
        reopened.edit(.init())
        do {
            try await reopened.load()
            XCTFail("Do not discard unsaved edits")
        } catch { XCTAssertEqual(reopened.draft, ContentDraft()) }
        XCTAssertTrue(reopened.hasUnsavedChanges)
    }

    @MainActor
    func testFailedEditorSaveKeepsEditsAndReportsFailure() async throws {
        let store = ContentDraftStore(file: try location())
        let first = ContentEditorModel(store: store)
        let second = ContentEditorModel(store: store)
        try await first.load()
        try await second.load()
        first.edit(draft())
        try await first.save()
        var newer = draft()
        newer.cards[0].title = "Other edit"
        second.edit(newer)
        do {
            try await second.save()
            XCTFail("Stale editor")
        } catch {
            XCTAssertEqual(second.draft, newer)
            XCTAssertTrue(second.hasUnsavedChanges)
            XCTAssertFalse(second.isBusy)
            XCTAssertNotNil(second.lastError)
        }
    }
}
