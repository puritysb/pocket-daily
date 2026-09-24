import Combine
import Foundation

/// Local-only editor state. Saving never creates a reader connection or sends
/// content. Deployment receives an immutable validated snapshot explicitly.
@MainActor
final class ContentEditorModel: ObservableObject {
    enum Failure: LocalizedError {
        case busy, unsavedChanges, changedCard, imageCollision, demo, notLoaded, staleImport
        var errorDescription: String? {
            switch self {
            case .busy: "A draft operation is already running. Wait for it to finish."
            case .unsavedChanges: "Save or keep a copy of your edits before reloading the draft."
            case .changedCard: "The card changed while the image was loading. Select the card and try again."
            case .imageCollision: "The image filename conflicts with another image. The draft was not changed."
            case .demo: "Demo content stays in memory and cannot import or export your files."
            case .notLoaded: "Load the saved content draft before importing or exporting."
            case .staleImport: "The content changed while import was open. Your edits were kept. Choose the file again to compare."
            }
        }
    }
    @Published private(set) var draft = ContentDraft()
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var recoveryBackup: URL?
    @Published private var savedDraft = ContentDraft()
    struct ImportProposal: Identifiable {
        let id = UUID()
        let sourceName: String
        let before: ContentDraft
        let draft: ContentDraft
        fileprivate let editGeneration: UInt64
    }
    @Published private(set) var pendingImport: ImportProposal?
    private var editGeneration: UInt64 = 0
    let isDemo: Bool
    private let importFile: @Sendable (URL) async throws -> ContentDraft
    private var generation: UInt64?
    private var recoveryID: UUID?
    private let store: ContentDraftStore

    var hasUnsavedChanges: Bool { draft != savedDraft }

    init(store: ContentDraftStore, isDemo: Bool = false,
         importFile: @escaping @Sendable (URL) async throws -> ContentDraft = { try await ContentDraftFile.load($0) }) {
        self.store = store
        self.isDemo = isDemo
        self.importFile = importFile
    }

    func exportDocument() throws -> ContentDraftDocument {
        guard !isDemo else { throw Failure.demo }
        guard !isBusy else { throw Failure.busy }
        guard hasLoaded else { throw Failure.notLoaded }
        try ContentDraftFile.validate(draft)
        return ContentDraftDocument(draft: draft)
    }

    func prepareImport(from url: URL) async throws {
        guard !isDemo else { throw Failure.demo }
        guard !isBusy else { throw Failure.busy }
        guard hasLoaded else { throw Failure.notLoaded }
        try Task.checkCancellation()
        isBusy = true
        pendingImport = nil
        defer { isBusy = false }
        let started = editGeneration
        let imported = try await importFile(url)
        try Task.checkCancellation()
        try ContentDraftFile.validate(imported)
        guard editGeneration == started else { throw Failure.staleImport }
        pendingImport = .init(sourceName: url.lastPathComponent, before: draft, draft: imported, editGeneration: started)
    }

    func confirmImport(id: UUID) throws {
        guard !isDemo else { throw Failure.demo }
        guard !isBusy else { throw Failure.busy }
        guard hasLoaded else { throw Failure.notLoaded }
        guard let proposal = pendingImport, proposal.id == id,
              proposal.editGeneration == editGeneration else { throw Failure.staleImport }
        pendingImport = nil
        edit(proposal.draft) // Memory only. Save and Apply are separate actions.
    }

    func cancelImport(id: UUID) {
        if pendingImport?.id == id { pendingImport = nil }
    }

    func edit(_ draft: ContentDraft) {
        editGeneration &+= 1
        self.draft = draft
        lastError = nil
    }

    func load() async throws {
        guard !isBusy else { throw Failure.busy }
        guard !hasUnsavedChanges else { throw Failure.unsavedChanges }
        isBusy = true
        defer { isBusy = false }
        let original = draft
        do {
            let saved = try await store.load()
            // Edits made while I/O was suspended are never overwritten.
            guard draft == original else { throw Failure.unsavedChanges }
            editGeneration &+= 1
            draft = saved?.draft ?? ContentDraft()
            savedDraft = draft
            generation = saved?.generation
            recoveryID = saved?.recoveryID
            hasLoaded = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func save() async throws {
        guard !isBusy else { throw Failure.busy }
        isBusy = true
        defer { isBusy = false }
        let snapshot = draft
        do {
            let saved = try await store.save(snapshot, replacing: generation, recoveryID: recoveryID)
            generation = saved.generation
            savedDraft = saved.draft
            // Do not replace draft: typing may have continued during the save.
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func deploymentSnapshot() throws -> ContentRevision { try draft.revision() }

    /// Requires a UI confirmation. Keeps current edits and preserves the prior
    /// disk file; recovery is never an implicit fallback from load/save.
    func recoverKeepingEdits() async throws {
        guard !isBusy else { throw Failure.busy }
        isBusy = true
        defer { isBusy = false }
        let snapshot = draft
        do {
            let recovery = try await store.recover(keeping: snapshot)
            generation = recovery.saved.generation
            recoveryID = recovery.saved.recoveryID
            savedDraft = recovery.saved.draft
            recoveryBackup = recovery.backup
            editGeneration &+= 1
            hasLoaded = true
            lastError = nil
        } catch {
            if let recovery = error as? ContentDraftStore.RecoveryFailure { recoveryBackup = recovery.backup }
            lastError = error.localizedDescription
            throw error
        }
    }

    func importImage(from url: URL, cardID: String) async throws {
        guard !isBusy else { throw Failure.busy }
        guard let original = draft.cards.first(where: { $0.id == cardID }) else { throw Failure.changedCard }
        isBusy = true
        defer { isBusy = false }
        do {
            let image = try await ContentImageImport.load(url)
            guard let current = draft.cards.first(where: { $0.id == cardID }), current == original else {
                throw Failure.changedCard
            }
            try attachImage(image, cardID: cardID)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func attachImage(_ image: ContentImageImport.Imported, cardID: String) throws {
        guard let index = draft.cards.firstIndex(where: { $0.id == cardID }),
              draft.cards.filter({ $0.id == cardID }).count == 1 else { throw Failure.changedCard }
        let decoded = try ContentImage.decode(image.data)
        guard decoded.width == image.width, decoded.height == image.height else {
            throw ContentImageImport.Failure.dimensions
        }
        guard ContentManifest.validPath(image.path, kind: .monoImage) else { throw ContentDraftStore.Failure.bounds }
        if let existing = draft.images[image.path], existing != image.data { throw Failure.imageCollision }
        var updated = draft
        updated.cards[index].imagePath = image.path
        updated.images[image.path] = image.data
        let referenced = Set(updated.cards.map(\.imagePath))
        updated.images = updated.images.filter { referenced.contains($0.key) }
        try updated.validateStorageBounds()
        edit(updated)
    }

    func removeImage(cardID: String) throws {
        guard !isBusy else { throw Failure.busy }
        guard let index = draft.cards.firstIndex(where: { $0.id == cardID }),
              draft.cards.filter({ $0.id == cardID }).count == 1 else { throw Failure.changedCard }
        var updated = draft
        updated.cards[index].imagePath = ""
        let referenced = Set(updated.cards.map(\.imagePath))
        updated.images = updated.images.filter { referenced.contains($0.key) }
        edit(updated)
    }
}
