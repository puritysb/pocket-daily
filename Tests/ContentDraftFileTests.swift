import XCTest
@testable import Pocket

/// Card sets offered for review (cards loaded from a reader) must be usable by
/// the editor, and the review cannot replace edits made while it was open.
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

    func testValidationRequiresUsableIdsAndExactImageReferences() throws {
        XCTAssertNoThrow(try ContentDraftFile.validate(draft()))
        // Unfinished text is allowed while editing.
        XCTAssertNoThrow(try ContentDraftFile.validate(.init(cards: [.init(id: "b", title: "", question: "")])))
        var invalid = draft()
        invalid.cards.append(invalid.cards[0])
        XCTAssertThrowsError(try ContentDraftFile.validate(invalid), "duplicate ID")
        invalid = draft()
        invalid.images["unused.pbm"] = invalid.images["image.pbm"]
        XCTAssertThrowsError(try ContentDraftFile.validate(invalid), "unreferenced image")
        invalid = draft()
        invalid.images = [:]
        XCTAssertThrowsError(try ContentDraftFile.validate(invalid), "missing image")
        invalid = draft()
        invalid.cards[0].id = "Upper Case"
        XCTAssertThrowsError(try ContentDraftFile.validate(invalid), "unusable ID")
        invalid = draft()
        invalid.images["image.pbm"] = Data("P4\n8 1\n".utf8)
        XCTAssertThrowsError(try ContentDraftFile.validate(invalid), "truncated image")
    }

    @MainActor func testStaleProposalCannotReplaceEditsOrSurviveReloadAndRecovery() async throws {
        let editor = ContentEditorModel(store: ContentDraftStore(file: try location()))
        try await editor.load()
        for change in 0..<3 {
            try editor.prepareImport(draft(), sourceName: "Cards on X3")
            let proposal = try XCTUnwrap(editor.pendingImport)
            if change == 0 { editor.edit(.init()) }
            if change == 1 { try await editor.load() }
            if change == 2 { try await editor.recoverKeepingEdits() }
            XCTAssertThrowsError(try editor.confirmImport(id: proposal.id))
            editor.cancelImport(id: proposal.id)
        }
    }

    @MainActor func testDemoAndUnloadedEditorsRefuseAReview() async throws {
        let store = ContentDraftStore(file: try location())
        for demo in [false, true] {
            let editor = ContentEditorModel(store: store, isDemo: demo)
            if demo { try await editor.load() }
            XCTAssertThrowsError(try editor.prepareImport(draft(), sourceName: "Cards on X3"))
            XCTAssertNil(editor.pendingImport)
        }
        let saved = try await store.load()
        XCTAssertNil(saved)
    }
}
