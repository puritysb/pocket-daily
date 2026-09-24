import XCTest
@testable import Pocket

final class ThemeDraftTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("theme.json")
    }

    func testReopenPreservesExactPackAndRejectsStaleWrites() async throws {
        let file = try location()
        let store = ThemeDraftStore(file: file)
        let missing = try await store.load()
        XCTAssertNil(missing)
        var draft = ThemeDraft()
        draft.headerHeight = 60
        draft.popupTextBold = false
        let first = try await store.save(draft, replacing: nil)
        let reopened = try await ThemeDraftStore(file: file).load()
        XCTAssertEqual(reopened, first)
        XCTAssertEqual(try UiPackEncoder.encode(name: "local", version: "1", theme: XCTUnwrap(reopened).draft.overrides),
                       try UiPackEncoder.encode(name: "local", version: "1", theme: draft.overrides))
        let bytes = try Data(contentsOf: file)
        let unchanged = try await store.save(draft, replacing: first.generation)
        XCTAssertEqual(unchanged, first)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        do { _ = try await store.save(.init(), replacing: nil); XCTFail("Stale draft replaced current data") }
        catch { XCTAssertEqual(error as? ThemeDraftStore.Failure, .conflict) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testMalformedUnknownOversizedAndInvalidMetadataCannotBeOverwritten() async throws {
        let file = try location()
        let encoder = JSONEncoder()
        let fixtures: [(Data, ThemeDraftStore.Failure)] = [
            (Data("broken".utf8), .corrupt),
            (Data("{\"schema\":3,\"futurePayload\":{}}".utf8), .unsupportedSchema),
            (Data(repeating: 0, count: ThemeDraftStore.maximumBytes + 1), .bounds),
            (try encoder.encode(ThemeDraftStore.Saved(schema: 1, generation: 0, draft: .init())), .invalidGeneration),
            (try encoder.encode(ThemeDraftStore.Saved(schema: 2, generation: 1, draft: .init())), .invalidGeneration),
        ]
        for (bytes, expected) in fixtures {
            try bytes.write(to: file)
            let store = ThemeDraftStore(file: file)
            do { _ = try await store.load(); XCTFail("Invalid draft accepted") }
            catch { XCTAssertEqual(error as? ThemeDraftStore.Failure, expected) }
            do { _ = try await store.save(.init(), replacing: nil); XCTFail("Invalid saved data overwritten") }
            catch { XCTAssertEqual(error as? ThemeDraftStore.Failure, expected) }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testBoundsAndGenerationExhaustionPreserveSavedFile() async throws {
        let file = try location()
        let saved = ThemeDraftStore.Saved(schema: 1, generation: .max, draft: .init())
        let bytes = try JSONEncoder().encode(saved)
        try bytes.write(to: file)
        let store = ThemeDraftStore(file: file)
        var changed = ThemeDraft()
        changed.headerHeight = 45
        do { _ = try await store.save(changed, replacing: .max); XCTFail("Generation wrapped") }
        catch { XCTAssertEqual(error as? ThemeDraftStore.Failure, .invalidGeneration) }
        for key in [\ThemeDraft.headerHeight, \.listRowHeight, \.menuRowHeight, \.menuSpacing,
                    \.tabBarHeight, \.contentSidePadding, \.popupCornerRadius] {
            var invalid = ThemeDraft()
            invalid[keyPath: key] = Int.max
            do { _ = try await store.save(invalid, replacing: .max); XCTFail("Invalid metric accepted") }
            catch { XCTAssertEqual(error as? ThemeDraftStore.Failure, .bounds) }
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testEveryMetricAcceptsItsBoundariesButRejectsOutOfRangeValues() throws {
        let fields: [(WritableKeyPath<ThemeDraft, Int>, ClosedRange<Int>)] = [
            (\.headerHeight, 20...120), (\.listRowHeight, 30...120), (\.menuRowHeight, 30...120),
            (\.menuSpacing, 0...32), (\.tabBarHeight, 20...80), (\.contentSidePadding, 0...64),
            (\.popupCornerRadius, 0...32),
        ]
        for (field, bounds) in fields {
            for value in [bounds.lowerBound, bounds.upperBound] {
                var draft = ThemeDraft()
                draft[keyPath: field] = value
                XCTAssertNoThrow(try draft.validate())
                XCTAssertNoThrow(try UiPackEncoder.encode(name: "local", version: "1", theme: draft.overrides))
            }
            for value in [bounds.lowerBound - 1, bounds.upperBound + 1] {
                var draft = ThemeDraft()
                draft[keyPath: field] = value
                XCTAssertThrowsError(try draft.validate())
            }
        }
    }

    func testRecoveryPreservesExactOversizedBytesAndRejectsOldGenerationEpoch() async throws {
        let file = try location()
        let store = ThemeDraftStore(file: file)
        let old = try await store.save(.init(), replacing: nil)
        let corrupt = Data(repeating: 0xFE, count: ThemeDraftStore.maximumBytes + 1)
        try corrupt.write(to: file)
        var draft = ThemeDraft()
        draft.headerHeight = 65
        let recovery = try await store.recover(keeping: draft)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery.backup)), corrupt)
        XCTAssertEqual(recovery.saved.schema, 2)
        XCTAssertEqual(recovery.saved.generation, old.generation)
        XCTAssertNotNil(recovery.saved.recoveryID)
        do { _ = try await store.save(.init(), replacing: old.generation); XCTFail("Pre-recovery editor overwrote new record") }
        catch { XCTAssertEqual(error as? ThemeDraftStore.Failure, .conflict) }
        draft.headerHeight = 66
        let saved = try await store.save(draft, replacing: recovery.saved.generation, recoveryID: recovery.saved.recoveryID)
        XCTAssertEqual(saved.generation, 2)
        XCTAssertEqual(saved.schema, 2)
        XCTAssertEqual(saved.recoveryID, recovery.saved.recoveryID)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery.backup)), corrupt)
    }

    func testRecoveryRejectsInvalidDraftAndNonRegularFilesWithoutReplacement() async throws {
        let file = try location()
        let original = Data("preserve me".utf8)
        try original.write(to: file)
        var invalid = ThemeDraft()
        invalid.headerHeight = 0
        do { _ = try await ThemeDraftStore(file: file).recover(keeping: invalid); XCTFail("Invalid recovery succeeded") }
        catch { XCTAssertEqual(error as? ThemeDraftStore.Failure, .bounds) }
        XCTAssertEqual(try Data(contentsOf: file), original)
        let directory = file.deletingLastPathComponent().appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do { _ = try await ThemeDraftStore(file: directory).recover(keeping: .init()); XCTFail("Directory was replaced") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path)) }
        let link = file.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try await ThemeDraftStore(file: link).recover(keeping: .init()); XCTFail("Symlink was replaced") }
        catch { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), file.path) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testEditorExplicitRecoveryKeepsBothDraftsAndDemoRefusesIt() async throws {
        let file = try location()
        let store = ThemeDraftStore(file: file)
        let editor = ThemeEditorModel(store: store)
        try await editor.load()
        _ = try await store.save(.init(), replacing: nil)
        let before = try Data(contentsOf: file)
        var draft = ThemeDraft()
        draft.menuSpacing = 16
        editor.edit(draft)
        do { try await editor.save(); XCTFail("Conflict expected") } catch { }
        try await editor.recoverKeepingEdits()
        XCTAssertEqual(editor.draft, draft)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.hasLoaded)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(editor.recoveryBackup)), before)
        draft.menuSpacing = 17
        editor.edit(draft)
        try await editor.save()
        let saved = try await store.load()
        XCTAssertEqual(saved?.draft, draft)
        XCTAssertEqual(saved?.schema, 2)
        let demo = ThemeEditorModel(store: nil)
        do { try await demo.recoverKeepingEdits(); XCTFail("Demo performed recovery") } catch { }
        XCTAssertNil(demo.recoveryBackup)
    }

    @MainActor
    func testSaveConflictRetainsUnsavedLocalEditsAndNewerDiskData() async throws {
        let store = ThemeDraftStore(file: try location())
        let first = ThemeEditorModel(store: store)
        let second = ThemeEditorModel(store: store)
        try await first.load()
        try await second.load()
        var draft = ThemeDraft()
        draft.headerHeight = 50
        first.edit(draft)
        try await first.save()
        draft.headerHeight = 51
        second.edit(draft)
        do { try await second.save(); XCTFail("Conflicting save succeeded") }
        catch { XCTAssertEqual(error as? ThemeDraftStore.Failure, .conflict) }
        XCTAssertEqual(second.draft, draft)
        XCTAssertTrue(second.hasUnsavedChanges)
        XCTAssertNotNil(second.lastError)
        let disk = try await store.load()
        XCTAssertEqual(disk?.draft, first.draft)
    }

    @MainActor
    func testSharedEditorSavesAndReopensWhileDemoCannotPersist() async throws {
        let store = ThemeDraftStore(file: try location())
        let editor = ThemeEditorModel(store: store)
        do { try await editor.save(); XCTFail("Save before load accepted") } catch { }
        try await editor.load()
        var draft = editor.draft
        draft.headerHeight = 70
        editor.edit(draft)
        XCTAssertTrue(editor.hasUnsavedChanges)
        try await editor.save()
        XCTAssertFalse(editor.hasUnsavedChanges)
        let reopened = ThemeEditorModel(store: store)
        try await reopened.load()
        XCTAssertEqual(reopened.draft, draft)
        let demo = ThemeEditorModel(store: nil)
        try await demo.load()
        XCTAssertEqual(demo.draft, ThemeDraft())
        demo.edit(draft)
        do { try await demo.save(); XCTFail("Demo saved") } catch { }
        XCTAssertTrue(demo.hasUnsavedChanges)
        let current = try await store.load()
        XCTAssertEqual(current?.generation, 1)
    }

    private actor SuspendedStore: ThemeDraftStorage {
        var loadContinuation: CheckedContinuation<ThemeDraftStore.Saved?, Error>?
        var saveContinuation: CheckedContinuation<ThemeDraftStore.Saved, Error>?
        var recoveryContinuation: CheckedContinuation<ThemeDraftStore.Recovery, Error>?
        var snapshot: ThemeDraft?
        var saveRecoveryID: UUID?
        var saveGeneration: UInt64?
        func load() async throws -> ThemeDraftStore.Saved? {
            try await withCheckedThrowingContinuation { loadContinuation = $0 }
        }
        func save(_ draft: ThemeDraft, replacing generation: UInt64?, recoveryID: UUID?) async throws -> ThemeDraftStore.Saved {
            snapshot = draft
            saveGeneration = generation
            saveRecoveryID = recoveryID
            return try await withCheckedThrowingContinuation { saveContinuation = $0 }
        }
        func recover(keeping draft: ThemeDraft) async throws -> ThemeDraftStore.Recovery {
            snapshot = draft
            return try await withCheckedThrowingContinuation { recoveryContinuation = $0 }
        }
        func loading() -> Bool { loadContinuation != nil }
        func saving() -> Bool { saveContinuation != nil }
        func recovering() -> Bool { recoveryContinuation != nil }
        func finishRecovery(epoch: UUID, backup: URL) {
            if let snapshot {
                recoveryContinuation?.resume(returning: .init(
                    saved: .init(schema: 2, generation: 1, draft: snapshot, recoveryID: epoch),
                    backup: backup))
            }
            recoveryContinuation = nil
        }
        func finishLoad() { loadContinuation?.resume(returning: nil); loadContinuation = nil }
        func finishSave() {
            if let snapshot {
                saveContinuation?.resume(returning: .init(
                    schema: saveRecoveryID == nil ? 1 : 2,
                    generation: (saveGeneration ?? 0) + 1,
                    draft: snapshot, recoveryID: saveRecoveryID))
            }
            saveContinuation = nil
        }
    }

    private func waitFor(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Controlled storage operation did not start")
    }

    @MainActor
    func testRecoveryKeepsLaterEditsAndCompletedReceiptDespiteCancellation() async throws {
        let store = SuspendedStore()
        let editor = ThemeEditorModel(store: store)
        var chosen = ThemeDraft()
        chosen.headerHeight = 60
        editor.edit(chosen)
        let recovery = Task { try await editor.recoverKeepingEdits() }
        try await waitFor { await store.recovering() }
        do { try await editor.recoverKeepingEdits(); XCTFail("Overlapping recovery started") }
        catch { XCTAssertTrue(editor.isBusy) }
        var later = chosen
        later.headerHeight = 61
        editor.edit(later)
        recovery.cancel()
        let epoch = UUID()
        let backup = try location()
        await store.finishRecovery(epoch: epoch, backup: backup)
        try await recovery.value
        XCTAssertEqual(editor.draft, later)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.hasLoaded)
        XCTAssertFalse(editor.isBusy)
        XCTAssertEqual(editor.recoveryBackup, backup)

        // The completed write must retain its new epoch even after cancellation;
        // otherwise the next explicit Save would fail against the recovered file.
        let save = Task { try await editor.save() }
        try await waitFor { await store.saving() }
        let savedEpoch = await store.saveRecoveryID
        let savedGeneration = await store.saveGeneration
        XCTAssertEqual(savedEpoch, epoch)
        XCTAssertEqual(savedGeneration, 1)
        await store.finishSave()
        try await save.value
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.draft, later)
    }

    @MainActor
    func testEditsDuringLoadAndSaveAreNeverDiscarded() async throws {
        let store = SuspendedStore()
        let editor = ThemeEditorModel(store: store)
        let load = Task { try await editor.load() }
        try await waitFor { await store.loading() }
        var draft = ThemeDraft()
        draft.headerHeight = 50
        editor.edit(draft)
        await store.finishLoad()
        do { try await load.value; XCTFail("Load discarded new edits") } catch { }
        XCTAssertEqual(editor.draft, draft)
        XCTAssertFalse(editor.hasLoaded)

        let writable = ThemeEditorModel(store: store)
        let open = Task { try await writable.load() }
        try await waitFor { await store.loading() }
        await store.finishLoad()
        try await open.value
        writable.edit(draft)
        let save = Task { try await writable.save() }
        try await waitFor { await store.saving() }
        draft.headerHeight = 51
        writable.edit(draft)
        await store.finishSave()
        try await save.value
        XCTAssertEqual(writable.draft, draft)
        XCTAssertTrue(writable.hasUnsavedChanges)
    }
}
