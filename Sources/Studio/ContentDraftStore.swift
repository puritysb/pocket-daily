import Foundation

/// Authoring data, not a deployment receipt. Incomplete text is allowed while
/// editing; only revision() can produce deployable, firmware-validated input.
struct ContentDraft: Codable, Equatable, Sendable {
    var cards: [ContentCard] = []
    var images: [String: Data] = [:]

    func revision() throws -> ContentRevision { try ContentRevision(cards: cards, images: images) }

    func validateStorageBounds() throws {
        guard cards.count <= 3, images.count <= 16 else { throw ContentDraftStore.Failure.bounds }
        for card in cards {
            guard [card.id, card.title, card.question, card.context, card.imagePath]
                .allSatisfy({ $0.utf8.count <= 4096 }) else { throw ContentDraftStore.Failure.bounds }
        }
        var total = 0
        for (path, bytes) in images {
            guard ContentManifest.validPath(path, kind: .monoImage), bytes.count <= 32779 else {
                throw ContentDraftStore.Failure.bounds
            }
            total += bytes.count
        }
        guard total <= 256 * 1024 else { throw ContentDraftStore.Failure.bounds }
    }
}

/// One app-owned actor serializes draft I/O off the main actor. Atomic writes
/// preserve the previous file on publication failure. Generation checks reject
/// stale editors; this is not a cross-process filesystem lock.
actor ContentDraftStore {
    struct Recovery: Sendable {
        let saved: Saved
        let backup: URL?
    }
    struct RecoveryFailure: LocalizedError {
        let backup: URL
        let underlying: Error
        var errorDescription: String? {
            "Recovery could not save the draft. The previous file was preserved at \(backup.path). \(underlying.localizedDescription)"
        }
    }
    struct Saved: Codable, Equatable, Sendable {
        let schema: UInt16
        let generation: UInt64
        let draft: ContentDraft
        let recoveryID: UUID?

        init(schema: UInt16, generation: UInt64, draft: ContentDraft, recoveryID: UUID? = nil) {
            self.schema = schema
            self.generation = generation
            self.draft = draft
            self.recoveryID = recoveryID
        }
    }
    enum Failure: LocalizedError, Equatable {
        case bounds, unsupportedSchema, invalidGeneration, conflict
        var errorDescription: String? {
            switch self {
            case .bounds: "The draft is too large. Use at most three cards and smaller images or text."
            case .unsupportedSchema: "This draft was saved by a newer app. Update the app before editing it."
            case .invalidGeneration: "The saved draft metadata is invalid. Preserve a copy before recovering the draft."
            case .conflict: "Another editor saved a newer draft. Keep your edits and compare them before replacing it."
            }
        }
    }
    private static let maximumBytes = 512 * 1024
    private let file: URL

    init(file: URL) { self.file = file }

    static func applicationStore() throws -> ContentDraftStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ContentDraftStore(file: base.appendingPathComponent("Pocket/Studio/content-draft.json"))
    }

    func load() throws -> Saved? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        defer { try? handle.close() }
        // Bound allocation even if another process replaces/grows the file.
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw Failure.bounds }
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        guard saved.schema == 1 || saved.schema == 2 else { throw Failure.unsupportedSchema }
        guard saved.generation > 0 else { throw Failure.invalidGeneration }
        try saved.draft.validateStorageBounds()
        return saved
    }

    @discardableResult
    func save(_ draft: ContentDraft, replacing generation: UInt64?, recoveryID: UUID? = nil) throws -> Saved {
        try draft.validateStorageBounds()
        let previous = try load() // Corrupt/unknown data must never become an empty draft.
        guard previous?.generation == generation, previous?.recoveryID == recoveryID else { throw Failure.conflict }
        if let previous, previous.draft == draft { return previous }
        let current = previous?.generation ?? 0
        guard current < UInt64.max else { throw Failure.invalidGeneration }
        let saved = Saved(schema: draft.cards.contains { $0.layout != .textFirst } ? 2 : 1,
                          generation: current + 1, draft: draft, recoveryID: recoveryID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(saved)
        guard data.count <= Self.maximumBytes else { throw Failure.bounds }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return saved
    }

    /// Explicit user recovery only. Preserve the current on-disk bytes, even
    /// if they cannot be decoded, before atomically publishing the chosen draft.
    /// Like save(), this actor serializes app callers, not external processes.
    func recover(keeping draft: ContentDraft) throws -> Recovery {
        try draft.validateStorageBounds()
        let saved = Saved(schema: draft.cards.contains { $0.layout != .textFirst } ? 2 : 1,
                          generation: 1, draft: draft, recoveryID: UUID())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(saved)
        guard data.count <= Self.maximumBytes else { throw Failure.bounds }
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var backup: URL?
        let attributes: [FileAttributeKey: Any]?
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            attributes = nil
        }
        if let attributes {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let destination = parent.appendingPathComponent("content-draft-backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: file, to: destination)
            backup = destination
        }
        do { try data.write(to: file, options: .atomic) }
        catch {
            if let backup { throw RecoveryFailure(backup: backup, underlying: error) }
            throw error
        }
        return Recovery(saved: saved, backup: backup)
    }
}

/// A card taken out of a draft, with the image only it referenced, so the
/// studio can undo a deletion even after later edits.
struct RemovedContentCard: Equatable, Sendable {
    let card: ContentCard
    let image: Data?
    let index: Int
}

extension ContentDraft {
    /// Removes a card and any image no remaining card references.
    func removingCard(at index: Int) -> (ContentDraft, RemovedContentCard)? {
        guard cards.indices.contains(index) else { return nil }
        var draft = self
        let card = draft.cards.remove(at: index)
        let referenced = Set(draft.cards.map(\.imagePath))
        let image = card.imagePath.isEmpty || referenced.contains(card.imagePath) ? nil : images[card.imagePath]
        draft.images = draft.images.filter { referenced.contains($0.key) }
        return (draft, RemovedContentCard(card: card, image: image, index: index))
    }

    /// Puts a removed card back at (or near) its old position. nil when it can
    /// no longer fit: the ID reappeared or the three-card limit is reached.
    func restoring(_ removed: RemovedContentCard, limit: Int = 3) -> ContentDraft? {
        guard cards.count < limit, !cards.contains(where: { $0.id == removed.card.id }) else { return nil }
        var draft = self
        draft.cards.insert(removed.card, at: min(removed.index, draft.cards.count))
        if let image = removed.image, !removed.card.imagePath.isEmpty { draft.images[removed.card.imagePath] = image }
        return draft
    }
}
