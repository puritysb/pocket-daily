import Foundation

/// Rules every card set the editor accepts must meet (the saved draft, cards
/// loaded from a reader). Publishing additionally validates the text.
enum ContentDraftFile {
    enum Failure: LocalizedError {
        case references
        var errorDescription: String? {
            "Card IDs or image references are invalid. Every image must be included and referenced."
        }
    }

    static func validate(_ draft: ContentDraft) throws {
        try draft.validateStorageBounds()
        guard Set(draft.cards.map(\.id)).count == draft.cards.count else { throw Failure.references }
        for card in draft.cards {
            // Unfinished text is allowed while editing. IDs and assets must
            // still be usable; publishing validates the actual text.
            _ = try ContentCard(id: card.id, title: "Draft", question: "Draft").encoded()
        }
        let references = Set(draft.cards.map(\.imagePath).filter { !$0.isEmpty })
        guard references == Set(draft.images.keys) else { throw Failure.references }
        for bytes in draft.images.values { _ = try ContentImage.decode(bytes) }
    }
}

#if DEBUG
/// UUID-scoped UI-test drafts only; never the user's saved content.
enum ContentDraftUITestFiles {
    static func storeURL(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketContentUITests/\(id.uuidString)/draft.json")
    }
}
#endif
