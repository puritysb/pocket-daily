import Foundation

/// One window's ordered draft writes run off the main actor. Revision checks
/// also reject an older queued save if task scheduling delivers it late.
actor ProfileDraftPersistence {
    private var latestRevision = 0
    private let store: ProfileEditStore

    init(store: ProfileEditStore = .live) { self.store = store }

    func load() throws -> ProfileEditSnapshot? { try store.loadChecked() }

    func save(_ snapshot: ProfileEditSnapshot?, revision: Int) throws {
        guard revision > latestRevision else { return }
        latestRevision = revision
        try store.save(snapshot)
    }
}
