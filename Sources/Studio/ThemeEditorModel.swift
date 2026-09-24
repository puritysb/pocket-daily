import Combine
import Foundation

@MainActor
final class ThemeEditorModel: ObservableObject {
    enum Failure: LocalizedError {
        case busy, unsavedChanges, notLoaded, demo, staleImport
        var errorDescription: String? {
            switch self {
            case .busy: "Wait for the current theme draft operation to finish."
            case .unsavedChanges: "Theme edits were kept. Save or preserve them before reloading."
            case .notLoaded: "Load the saved theme draft before saving changes."
            case .demo: "Demo theme edits stay in memory and cannot replace your saved draft."
            case .staleImport: "The draft changed while import was open. Your current edits were kept. Choose the file again to compare them."
            }
        }
    }

    @Published private(set) var draft = ThemeDraft()
    @Published private(set) var hasLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published private(set) var recoveryBackup: URL?
    struct ImportProposal: Identifiable {
        let id = UUID()
        let sourceName: String
        let before: ThemeDraft
        let draft: ThemeDraft
        fileprivate let editGeneration: UInt64
    }
    @Published private(set) var pendingImport: ImportProposal?
    @Published private var savedDraft = ThemeDraft()
    private var generation: UInt64?
    private var recoveryID: UUID?
    private var editGeneration: UInt64 = 0
    private let store: (any ThemeDraftStorage)?
    private let importFile: @Sendable (URL) async throws -> ThemeDraft
    var hasUnsavedChanges: Bool { draft != savedDraft }
    var isDemo: Bool { store == nil }

    /// nil is an isolated demo document: no persistence dependency exists.
    init(store: (any ThemeDraftStorage)?,
         importFile: @escaping @Sendable (URL) async throws -> ThemeDraft = { try await ThemeDraftFile.load($0) }) {
        self.store = store
        self.importFile = importFile
    }

    func exportDocument() throws -> ThemeDraftDocument {
        guard !isDemo else { throw Failure.demo }
        guard !isBusy else { throw Failure.busy }
        guard hasLoaded else { throw Failure.notLoaded }
        try draft.validate()
        return ThemeDraftDocument(draft: draft)
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
        try imported.validate()
        guard editGeneration == started else { throw Failure.staleImport }
        pendingImport = .init(sourceName: url.lastPathComponent, before: draft,
                              draft: imported, editGeneration: started)
    }

    func confirmImport(id: UUID) throws {
        guard !isDemo else { throw Failure.demo }
        guard !isBusy else { throw Failure.busy }
        guard hasLoaded else { throw Failure.notLoaded }
        guard let proposal = pendingImport, proposal.id == id,
              proposal.editGeneration == editGeneration else { throw Failure.staleImport }
        pendingImport = nil
        edit(proposal.draft) // Memory only: Save and Apply remain explicit actions.
    }

    func cancelImport(id: UUID) {
        if pendingImport?.id == id { pendingImport = nil }
    }

    func edit(_ draft: ThemeDraft) {
        editGeneration &+= 1
        self.draft = draft
        lastError = nil
    }

    func load() async throws {
        guard !isBusy else { throw Failure.busy }
        guard !hasUnsavedChanges else { throw Failure.unsavedChanges }
        try Task.checkCancellation()
        isBusy = true
        defer { isBusy = false }
        let started = editGeneration
        do {
            let saved = try await store?.load()
            try Task.checkCancellation()
            guard editGeneration == started else { throw Failure.unsavedChanges }
            editGeneration &+= 1
            draft = saved?.draft ?? ThemeDraft()
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
        guard let store else { throw Failure.demo }
        guard !isBusy else { throw Failure.busy }
        guard hasLoaded else { throw Failure.notLoaded }
        try Task.checkCancellation()
        isBusy = true
        defer { isBusy = false }
        let snapshot = draft
        do {
            let saved = try await store.save(snapshot, replacing: generation, recoveryID: recoveryID)
            // A completed local write is recorded even if the caller has since
            // cancelled. Never lose its generation or overwrite newer typing.
            generation = saved.generation
            savedDraft = saved.draft
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// UI must obtain explicit confirmation. Never called as a load fallback.
    func recoverKeepingEdits() async throws {
        guard let store else { throw Failure.demo }
        guard !isBusy else { throw Failure.busy }
        try Task.checkCancellation()
        isBusy = true
        defer { isBusy = false }
        let snapshot = draft
        do {
            let recovery = try await store.recover(keeping: snapshot)
            generation = recovery.saved.generation
            recoveryID = recovery.saved.recoveryID
            savedDraft = recovery.saved.draft
            recoveryBackup = recovery.backup
            hasLoaded = true
            lastError = nil
        } catch {
            if let failure = error as? ThemeDraftStore.RecoveryFailure { recoveryBackup = failure.backup }
            lastError = error.localizedDescription
            throw error
        }
    }
}
