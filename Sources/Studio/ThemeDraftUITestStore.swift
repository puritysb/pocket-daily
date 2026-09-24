#if DEBUG
import Foundation

/// Explicit UI-test fixture only. A UUID scopes it away from the user's normal
/// draft; release builds contain neither this store nor the environment hook.
actor ThemeDraftUITestStore: ThemeDraftStorage {
    private let file: URL
    private let store: ThemeDraftStore

    init(id: UUID) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketThemeUITests/\(id.uuidString)/theme.json")
        self.file = file
        store = ThemeDraftStore(file: file)
    }

    func load() async throws -> ThemeDraftStore.Saved? {
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("UI-test corrupt theme draft".utf8).write(to: file, options: .withoutOverwriting)
        }
        return try await store.load()
    }

    func save(_ draft: ThemeDraft, replacing generation: UInt64?, recoveryID: UUID?) async throws -> ThemeDraftStore.Saved {
        try await store.save(draft, replacing: generation, recoveryID: recoveryID)
    }

    func recover(keeping draft: ThemeDraft) async throws -> ThemeDraftStore.Recovery {
        try await store.recover(keeping: draft)
    }

    /// Tests the real bounded file reader and review UI without depending on a
    /// simulator's Files providers. Native picker/provider behavior is separate.
    static func importFixture(id: UUID) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("PocketThemeUITests/\(id.uuidString)/import.pocket-theme.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                var draft = ThemeDraft()
                draft.headerHeight = 70
                try ThemeDraftFile.encode(draft).write(to: file, options: .withoutOverwriting)
            }
            return file
        }.value
    }
}
#endif
