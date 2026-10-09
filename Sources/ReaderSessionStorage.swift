import Foundation

/// A registration owns its files and preferences for its entire lifetime.
/// The first registration keeps the old paths so upgrades do not orphan work.
struct ReaderSessionStorage {
    let root: URL?
    let defaults: UserDefaults

    static let legacy = ReaderSessionStorage(root: nil, defaults: .standard)
    var transfers: URL { root?.appendingPathComponent("Transfers") ?? TransferPreparation.directory }
    var profileEdits: ProfileEditStore {
        root.map { ProfileEditStore(url: $0.appendingPathComponent("Studio/profile-edits.json")) } ?? .live
    }
    var jobs: BookTransferJobStore {
        root.map { BookTransferJobStore(file: $0.appendingPathComponent("book-transfer-jobs.json")) } ?? BookTransferJobStore()
    }

    func localFiles() -> PocketModel.LocalFileOperations {
        let directory = transfers
        return PocketModel.LocalFileOperations(prepare: { source in
            try await Task.detached(priority: .userInitiated) {
                try TransferPreparation.prepare(source, directory: directory)
            }.value
        }, prepareBook: { source, id, jobID, bookID in
            try await Task.detached(priority: .userInitiated) {
                try TransferPreparation.prepare(source, directory: directory, id: id, bookJobID: jobID, libraryBookID: bookID)
            }.value
        })
    }
}
