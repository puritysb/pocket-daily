import XCTest
@testable import Pocket

final class ThemeDraftFileTests: XCTestCase {
    private func location() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }
        return parent.appendingPathComponent("theme.json")
    }

    func testPortableRoundTripPreservesPackBytesWithoutStoreMetadata() throws {
        var draft = ThemeDraft()
        draft.headerHeight = 72
        draft.popupTextBold = false
        let bytes = try ThemeDraftFile.encode(draft)
        let decoded = try ThemeDraftFile.decode(bytes)
        XCTAssertEqual(decoded, draft)
        XCTAssertEqual(try UiPackEncoder.encode(name: "portable", version: "1", theme: decoded.overrides),
                       try UiPackEncoder.encode(name: "portable", version: "1", theme: draft.overrides))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["format", "schema", "draft"])
        XCTAssertNil(root["generation"])
        XCTAssertNil(root["deviceID"])
        XCTAssertNil(root["recoveryID"])
    }

    func testRejectsUnknownMissingMalformedAndOutOfRangeFields() throws {
        let valid = try ThemeDraftFile.encode(.init())
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var variants: [[String: Any]] = []
        for (key, value) in [("format", "other" as Any), ("schema", 2 as Any),
                             ("schema", true as Any), ("schema", 1.5 as Any), ("extra", "future" as Any)] {
            var altered = base
            altered[key] = value
            variants.append(altered)
        }
        for (key, value) in [("headerHeight", 121 as Any), ("popupTextBold", 1 as Any),
                             ("newField", 1 as Any), ("headerHeight", NSNull() as Any)] {
            var altered = base
            var fields = try XCTUnwrap(altered["draft"] as? [String: Any])
            fields[key] = value
            altered["draft"] = fields
            variants.append(altered)
        }
        var missing = base
        missing.removeValue(forKey: "draft")
        variants.append(missing)
        for variant in variants {
            XCTAssertThrowsError(try ThemeDraftFile.decode(JSONSerialization.data(withJSONObject: variant)))
        }
        for bytes in [Data(), Data("broken".utf8), Data("[]".utf8),
                      valid + Data(repeating: 32, count: ThemeDraftFile.maximumBytes)] {
            XCTAssertThrowsError(try ThemeDraftFile.decode(bytes))
        }
        var invalid = ThemeDraft()
        invalid.headerHeight = -1
        XCTAssertThrowsError(try ThemeDraftFile.encode(invalid))
        // The private on-disk record is intentionally not a portable document.
        XCTAssertThrowsError(try ThemeDraftFile.decode(JSONEncoder().encode(
            ThemeDraftStore.Saved(schema: 1, generation: 1, draft: .init()))))
    }

    func testBoundedFileReadDoesNotChangeSource() async throws {
        let file = try location()
        let bytes = try ThemeDraftFile.encode(.init())
        try bytes.write(to: file)
        let loaded = try await ThemeDraftFile.load(file)
        XCTAssertEqual(loaded, ThemeDraft())
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let oversized = Data(repeating: 32, count: ThemeDraftFile.maximumBytes + 1)
        try oversized.write(to: file)
        do { _ = try await ThemeDraftFile.load(file); XCTFail("Oversized import accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), oversized)
    }

    @MainActor
    func testImportConfirmationAndExportRemainLocalUntilExplicitSave() async throws {
        let store = ThemeDraftStore(file: try location())
        var imported = ThemeDraft()
        imported.headerHeight = 70
        let candidate = imported
        let editor = ThemeEditorModel(store: store, importFile: { _ in candidate })
        try await editor.load()
        let source = URL(fileURLWithPath: "/selected/theme.json")
        try await editor.prepareImport(from: source)
        let cancelled = try XCTUnwrap(editor.pendingImport)
        XCTAssertEqual(editor.draft, .init())
        editor.cancelImport(id: cancelled.id)
        XCTAssertNil(editor.pendingImport)
        try await editor.prepareImport(from: source)
        let proposal = try XCTUnwrap(editor.pendingImport)
        XCTAssertEqual(proposal.sourceName, "theme.json")
        XCTAssertEqual(proposal.before, .init())
        try editor.confirmImport(id: proposal.id)
        XCTAssertEqual(editor.draft, candidate)
        XCTAssertTrue(editor.hasUnsavedChanges)
        let untouched = try await store.load()
        XCTAssertNil(untouched)
        let exported = try editor.exportDocument()
        editor.edit(.init())
        XCTAssertEqual(exported.draft, candidate) // Export is an immutable snapshot.
        editor.edit(candidate)
        try await editor.save()
        let saved = try await store.load()
        XCTAssertEqual(saved?.draft, candidate)
    }

    @MainActor
    func testDemoUnloadedAndInvalidImportCannotChangeDraftOrStore() async throws {
        let source = URL(fileURLWithPath: "/must-not-open")
        let demo = ThemeEditorModel(store: nil, importFile: { _ in
            XCTFail("Demo accessed a file")
            return .init()
        })
        try await demo.load()
        XCTAssertThrowsError(try demo.exportDocument())
        do { try await demo.prepareImport(from: source); XCTFail("Demo imported") } catch { }
        let store = ThemeDraftStore(file: try location())
        let editor = ThemeEditorModel(store: store, importFile: { _ in
            var invalid = ThemeDraft()
            invalid.headerHeight = 0
            return invalid
        })
        XCTAssertThrowsError(try editor.exportDocument())
        do { try await editor.prepareImport(from: source); XCTFail("Unloaded editor imported") } catch { }
        try await editor.load()
        do { try await editor.prepareImport(from: source); XCTFail("Invalid draft imported") } catch { }
        XCTAssertEqual(editor.draft, .init())
        XCTAssertNil(editor.pendingImport)
        XCTAssertNil(editor.lastError, "Import errors must not advertise saved-file recovery")
        let saved = try await store.load()
        XCTAssertNil(saved)
    }

    private actor Loader {
        var continuation: CheckedContinuation<ThemeDraft, Error>?
        func load() async throws -> ThemeDraft {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func started() -> Bool { continuation != nil }
        func finish() { continuation?.resume(returning: .init()); continuation = nil }
    }

    @MainActor
    func testReloadInvalidatesImportEvenWhenDraftValuesAreUnchanged() async throws {
        let store = ThemeDraftStore(file: try location())
        let editor = ThemeEditorModel(store: store, importFile: { _ in
            var imported = ThemeDraft()
            imported.headerHeight = 70
            return imported
        })
        try await editor.load()
        let original = editor.draft
        try await editor.prepareImport(from: URL(fileURLWithPath: "/selected/theme.json"))
        let proposal = try XCTUnwrap(editor.pendingImport)
        // Another window can reload the shared model while a review is open.
        try await editor.load()
        XCTAssertEqual(editor.draft, original)
        XCTAssertThrowsError(try editor.confirmImport(id: proposal.id)) { error in
            guard case ThemeEditorModel.Failure.staleImport = error else {
                return XCTFail("Expected stale import, got \(error)")
            }
        }
        XCTAssertEqual(editor.draft, original)
        XCTAssertFalse(editor.hasUnsavedChanges)
        let saved = try await store.load()
        XCTAssertNil(saved)
    }

    @MainActor
    func testLaterEditsABAAndCancellationRefuseStaleImports() async throws {
        let loader = Loader()
        let editor = ThemeEditorModel(store: ThemeDraftStore(file: try location()), importFile: { _ in
            try await loader.load()
        })
        try await editor.load()
        let source = URL(fileURLWithPath: "/selected/theme.json")
        for cancelled in [false, true] {
            let operation = Task { try await editor.prepareImport(from: source) }
            for _ in 0..<1000 {
                if await loader.started() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let started = await loader.started()
            XCTAssertTrue(started)
            do { try await editor.prepareImport(from: source); XCTFail("Concurrent import started") } catch { }
            if cancelled { operation.cancel() }
            else {
                var changed = ThemeDraft()
                changed.headerHeight = 45
                editor.edit(changed)
                editor.edit(.init()) // ABA still changes the edit generation.
            }
            await loader.finish()
            do { try await operation.value; XCTFail("Stale/cancelled import accepted") } catch { }
            XCTAssertNil(editor.pendingImport)
            XCTAssertFalse(editor.isBusy)
        }
        let immediate = ThemeEditorModel(store: ThemeDraftStore(file: try location()), importFile: { _ in .init() })
        try await immediate.load()
        try await immediate.prepareImport(from: source)
        let proposal = try XCTUnwrap(immediate.pendingImport)
        immediate.cancelImport(id: UUID())
        XCTAssertNotNil(immediate.pendingImport)
        var changed = ThemeDraft()
        changed.headerHeight = 51
        immediate.edit(changed)
        XCTAssertThrowsError(try immediate.confirmImport(id: proposal.id))
        XCTAssertEqual(immediate.draft, changed)
        immediate.cancelImport(id: proposal.id)
        XCTAssertNil(immediate.pendingImport)
    }
}
