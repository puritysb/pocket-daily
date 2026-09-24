import XCTest
@testable import Pocket

final class ContentDraftFileTests: XCTestCase {
    private func location() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("content.json")
    }
    private func draft() -> ContentDraft {
        .init(cards: [.init(id: "a", title: "오늘", question: "Read", context: "Keep going", imagePath: "image.pbm", layout: .sideBySide)],
              images: ["image.pbm": Data("P4\n8 1\n".utf8) + Data([0x81])])
    }

    func testRoundTripPreservesEveryAssetLayoutAndRevisionWithoutPrivateMetadata() throws {
        let original = draft()
        let bytes = try ContentDraftFile.encode(original)
        let decoded = try ContentDraftFile.decode(bytes)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try decoded.revision().revision, try original.revision().revision)
        XCTAssertEqual(try decoded.revision().manifest, try original.revision().manifest)
        XCTAssertEqual(try ContentDraftFile.encode(decoded), bytes)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["format", "schema", "draft"])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("deviceID"))
        XCTAssertThrowsError(try ContentDraftFile.decode(JSONEncoder().encode(
            ContentDraftStore.Saved(schema: 2, generation: 1, draft: original))))
    }

    func testIncompleteTextAndEmptyDocumentRemainPortableButNotImplicitlyPublishable() throws {
        var unfinished = draft()
        unfinished.cards[0].title = ""
        unfinished.cards[0].question = String(repeating: "x", count: 200)
        XCTAssertEqual(try ContentDraftFile.decode(ContentDraftFile.encode(unfinished)), unfinished)
        XCTAssertThrowsError(try unfinished.revision())
        XCTAssertEqual(try ContentDraftFile.decode(ContentDraftFile.encode(.init())), .init())
    }

    func testRejectsMalformedFieldsVersionsAssetsAndMissingReferences() throws {
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: ContentDraftFile.encode(draft())) as? [String: Any])
        for (key, value) in [("schema", 2 as Any), ("schema", true as Any), ("schema", 1.5 as Any),
                             ("format", "other" as Any), ("extra", 1 as Any)] {
            var root = base
            root[key] = value
            XCTAssertThrowsError(try ContentDraftFile.decode(JSONSerialization.data(withJSONObject: root)))
        }
        for (key, value) in [("layout", 3 as Any), ("layout", NSNull() as Any), ("future", 1 as Any), ("question", 1 as Any)] {
            var root = base
            var fields = try XCTUnwrap(root["draft"] as? [String: Any])
            var cards = try XCTUnwrap(fields["cards"] as? [[String: Any]])
            cards[0][key] = value
            fields["cards"] = cards
            root["draft"] = fields
            XCTAssertThrowsError(try ContentDraftFile.decode(JSONSerialization.data(withJSONObject: root)))
        }
        var invalid = draft()
        invalid.images = [:]
        XCTAssertThrowsError(try ContentDraftFile.encode(invalid))
        invalid = draft(); invalid.images["extra.pbm"] = invalid.images["image.pbm"]
        XCTAssertThrowsError(try ContentDraftFile.encode(invalid))
        invalid = draft(); invalid.images["image.pbm"] = Data([0])
        XCTAssertThrowsError(try ContentDraftFile.encode(invalid))
        invalid = draft(); invalid.cards.append(invalid.cards[0])
        XCTAssertThrowsError(try ContentDraftFile.encode(invalid))
        invalid = draft(); invalid.cards[0].id = "../bad"
        XCTAssertThrowsError(try ContentDraftFile.encode(invalid))
        for bytes in [Data(), Data("{}".utf8), Data("[]".utf8), Data(repeating: 32, count: ContentDraftFile.maximumBytes + 1)] {
            XCTAssertThrowsError(try ContentDraftFile.decode(bytes))
        }
    }

    func testBoundedReadPreservesSourceAndRejectsOversize() async throws {
        let file = try location()
        let bytes = try ContentDraftFile.encode(draft())
        try bytes.write(to: file)
        let loaded = try await ContentDraftFile.load(file)
        XCTAssertEqual(loaded, draft())
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let oversized = Data(repeating: 0, count: ContentDraftFile.maximumBytes + 1)
        try oversized.write(to: file)
        do { _ = try await ContentDraftFile.load(file); XCTFail("Oversized") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), oversized)
    }

    @MainActor func testCancelConfirmExportAndSaveHaveDistinctEffects() async throws {
        let store = ContentDraftStore(file: try location())
        let imported = draft()
        let editor = ContentEditorModel(store: store, importFile: { _ in imported })
        try await editor.load()
        let url = URL(fileURLWithPath: "/selected/content.json")
        try await editor.prepareImport(from: url)
        let cancelled = try XCTUnwrap(editor.pendingImport)
        XCTAssertEqual(editor.draft, .init())
        editor.cancelImport(id: cancelled.id)
        XCTAssertNil(editor.pendingImport)
        try await editor.prepareImport(from: url)
        let proposal = try XCTUnwrap(editor.pendingImport)
        XCTAssertEqual(proposal.before, .init())
        XCTAssertEqual(proposal.draft, imported)
        try editor.confirmImport(id: proposal.id)
        XCTAssertEqual(editor.draft, imported)
        let savedBefore = try await store.load()
        XCTAssertNil(savedBefore)
        let exported = try editor.exportDocument()
        editor.edit(.init())
        XCTAssertEqual(exported.draft, imported)
        editor.edit(imported)
        try await editor.save()
        let reopened = ContentEditorModel(store: store)
        try await reopened.load()
        XCTAssertEqual(reopened.draft, imported)
    }

    @MainActor func testStaleProposalCannotReplaceEditsOrSurviveReloadAndRecovery() async throws {
        let editor = ContentEditorModel(store: ContentDraftStore(file: try location()), importFile: { _ in .init() })
        try await editor.load()
        for change in 0..<3 {
            try await editor.prepareImport(from: URL(fileURLWithPath: "/selected/content.json"))
            let proposal = try XCTUnwrap(editor.pendingImport)
            if change == 0 { editor.edit(.init()) }
            if change == 1 { try await editor.load() }
            if change == 2 { try await editor.recoverKeepingEdits() }
            XCTAssertThrowsError(try editor.confirmImport(id: proposal.id))
            editor.cancelImport(id: proposal.id)
        }
    }

    @MainActor func testDemoAndUnloadedEditorNeverReadImportSource() async throws {
        let store = ContentDraftStore(file: try location())
        for demo in [false, true] {
            let editor = ContentEditorModel(store: store, isDemo: demo, importFile: { _ in
                XCTFail("Unauthorized import read")
                return .init()
            })
            if demo { try await editor.load() }
            XCTAssertThrowsError(try editor.exportDocument())
            do { try await editor.prepareImport(from: URL(fileURLWithPath: "/must-not-read")); XCTFail("Import admitted") } catch { }
            XCTAssertNil(editor.pendingImport)
            XCTAssertNil(editor.lastError, "Import must not advertise storage recovery")
        }
        let saved = try await store.load()
        XCTAssertNil(saved)
    }
}
