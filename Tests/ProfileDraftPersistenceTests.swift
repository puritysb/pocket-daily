import XCTest
@testable import Pocket

final class ProfileDraftPersistenceTests: XCTestCase {
    /// A completion from an older queued editor snapshot must never replace
    /// the newer draft, including after the newer draft is explicitly cleared.
    func testOlderQueuedSnapshotsCannotResurrectDiscardedDraft() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProfileEditStore(url: folder.appendingPathComponent("draft.json"))
        let persistence = ProfileDraftPersistence(store: store)
        var staleProfile = PocketProfile.defaults
        staleProfile.home.weather = .top
        let stale = ProfileEditSnapshot(draft: staleProfile, base: .defaults, baseGeneration: nil,
                                        reading: ReaderPreferences(), readingBase: ReaderPreferences(), savedAt: Date())
        var latest = stale
        latest.draft.home.weather = .off
        try await persistence.save(latest, revision: 2)
        try await persistence.save(stale, revision: 1)
        let loaded = try await persistence.load()
        XCTAssertEqual(loaded?.draft.home.weather, .off)
        try await persistence.save(nil, revision: 4)
        try await persistence.save(stale, revision: 3)
        let afterDiscard = try await persistence.load()
        XCTAssertNil(afterDiscard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url?.path ?? ""))
    }
}
