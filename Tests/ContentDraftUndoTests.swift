import XCTest
@testable import Pocket

final class ContentDraftUndoTests: XCTestCase {
    private func card(_ id: String, image: String = "") -> ContentCard {
        ContentCard(id: id, title: id.uppercased(), question: "Q \(id)", imagePath: image)
    }

    func testRemovingDropsOnlyTheImageNoOtherCardUses() throws {
        let draft = ContentDraft(cards: [card("a", image: "a.pbm"), card("b", image: "shared.pbm"), card("c", image: "shared.pbm")],
                                 images: ["a.pbm": Data([1]), "shared.pbm": Data([2])])
        let (withoutA, removedA) = try XCTUnwrap(draft.removingCard(at: 0))
        XCTAssertEqual(withoutA.cards.map(\.id), ["b", "c"])
        XCTAssertNil(withoutA.images["a.pbm"])
        XCTAssertEqual(removedA.image, Data([1]))

        let (withoutB, removedB) = try XCTUnwrap(draft.removingCard(at: 1))
        XCTAssertEqual(withoutB.images["shared.pbm"], Data([2]), "Still used by c")
        XCTAssertNil(removedB.image)
        XCTAssertNil(draft.removingCard(at: 3))
    }

    func testRestoringPutsTheCardAndImageBackAtItsPosition() throws {
        let draft = ContentDraft(cards: [card("a"), card("b", image: "b.pbm"), card("c")], images: ["b.pbm": Data([9])])
        let (without, removed) = try XCTUnwrap(draft.removingCard(at: 1))
        XCTAssertEqual(try XCTUnwrap(without.restoring(removed)), draft)
    }

    func testRestoringSurvivesLaterEditsAndRefusesConflicts() throws {
        let draft = ContentDraft(cards: [card("a"), card("b"), card("c")])
        var (edited, removed) = try XCTUnwrap(draft.removingCard(at: 2))
        edited.cards[0].title = "EDITED"
        let restored = try XCTUnwrap(edited.restoring(removed))
        XCTAssertEqual(restored.cards.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(restored.cards[0].title, "EDITED", "Later edits are kept")

        XCTAssertNil(draft.restoring(removed), "Already at the three-card limit")
        var reused = edited
        reused.cards.append(card("c"))
        XCTAssertNil(reused.restoring(removed), "The ID is back in use")
    }
}
