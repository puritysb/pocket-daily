import XCTest
@testable import Pocket

final class ProfileMergeTests: XCTestCase {
    private var base: PocketProfile { .defaults }

    func testUntouchedFieldsFollowTheReaderAndEditedOnesAreKept() {
        var mine = base
        mine.home.weather = .top                    // edited here only
        var reader = base
        reader.sleep.mode = .reader                 // changed on the reader only
        let merged = ProfileMerge.merge(base: base, mine: mine, reader: reader)
        XCTAssertEqual(merged.profile.home.weather, .top)
        XCTAssertEqual(merged.profile.sleep.mode, .reader)
        XCTAssertEqual(merged.report.fromReader, [.sleepMode])
        XCTAssertEqual(merged.report.bothChanged, [])
    }

    func testAFieldChangedOnBothSidesKeepsMineAndIsReported() {
        var mine = base
        mine.home.items = [.study, .reading]
        var reader = base
        reader.home.items = [.reading]
        let merged = ProfileMerge.merge(base: base, mine: mine, reader: reader)
        XCTAssertEqual(merged.profile.home.items, [.study, .reading])
        XCTAssertEqual(merged.report.bothChanged, [.homeItems])

        var same = base
        same.home.nextEvent = false
        let agreed = ProfileMerge.merge(base: base, mine: same, reader: same)
        XCTAssertTrue(agreed.report.isEmpty, "Both making the same change is not a conflict")
    }

    func testReadingSettingsMergeTheSameWayAndNeverSendWhatTheReaderLacks() {
        let readerBase = ReaderPreferences(startupApp: 1, fontSize: 1, sideButtons: .previousNext,
                                           frontButtonsFollowOrientation: false, sleepWakeIndicator: true)
        var mine = readerBase
        mine.fontSize = 3
        mine.sleepTimeoutMinutes = 20
        var reader = readerBase
        reader.sleepTimeoutMinutes = 5
        reader.startupApp = 0
        reader.sleepWakeIndicator = nil              // reinstalled firmware without the setting
        let merged = ProfileMerge.merge(base: readerBase, mine: mine, reader: reader)
        XCTAssertEqual(merged.preferences.fontSize, 3)
        XCTAssertEqual(merged.preferences.startupApp, 0)
        XCTAssertEqual(merged.preferences.sleepTimeoutMinutes, 20)
        XCTAssertNil(merged.preferences.sleepWakeIndicator)
        XCTAssertEqual(merged.report.fromReader, [.startup, .wakeCue])
        XCTAssertEqual(merged.report.bothChanged, [.sleepTimeout])
    }

    func testPendingFieldsNameWhatApplyChanges() {
        var mine = base
        mine.home.dailyWord = false
        mine.sleep.sections = [.reading]
        XCTAssertEqual(ProfileMerge.pending(profile: mine, reader: base), [.dailyWord, .sleepSections])
        XCTAssertEqual(ProfileMerge.pending(profile: base, reader: base), [])
    }

    func testSnapshotRoundTripsAndACleanEditorRemovesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProfileEditStore(url: url)
        var draft = base
        draft.home.weather = .off
        let snapshot = ProfileEditSnapshot(draft: draft, base: base, baseGeneration: 4,
                                           reading: ReaderPreferences(fontSize: 2), readingBase: ReaderPreferences(),
                                           savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
        try store.save(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(ProfileEditStore(url: nil).load(), "Hosted tests keep no file")
    }

    @MainActor
    func testSavedEditsMergeWithTheReaderOnTheNextConnection() {
        // Saved offline against generation 4; the reader is now at generation 5.
        var draft = base
        draft.home.weather = .top
        draft.home.nextEvent = false
        let editor = ProfileEditorState()
        editor.restore(ProfileEditSnapshot(draft: draft, base: base, baseGeneration: 4,
                                           reading: ReaderPreferences(), readingBase: ReaderPreferences(),
                                           savedAt: Date()))
        XCTAssertNotNil(editor.snapshot)
        var reader = base
        reader.home.weather = .off                    // both changed
        reader.sleep.mode = .reader                   // reader only
        editor.sync(with: ReaderProfileState(deviceID: "1234ABCD", generation: 5, profile: reader, maxHomeItems: 4))
        XCTAssertEqual(editor.draft.home.weather, .top)
        XCTAssertEqual(editor.draft.sleep.mode, .reader)
        XCTAssertEqual(editor.draft.home.nextEvent, false)
        XCTAssertEqual(editor.mergeReport?.fromReader, [.sleepMode])
        XCTAssertEqual(editor.mergeReport?.bothChanged, [.weather])
        XCTAssertEqual(editor.pendingFields, [.weather, .nextEvent])

        editor.useReaderForBothChanged()
        XCTAssertEqual(editor.draft.home.weather, .off)
        XCTAssertEqual(editor.pendingFields, [.nextEvent])
        XCTAssertNotNil(editor.mergeReport, "What came from the reader stays listed until dismissed")
        editor.dismissMergeReport()
        XCTAssertNil(editor.mergeReport)
    }

    @MainActor
    func testACleanEditorSimplyAdoptsTheReader() {
        let editor = ProfileEditorState()
        var reader = base
        reader.home.items = [.reading]
        editor.sync(with: ReaderProfileState(deviceID: "1234ABCD", generation: 1, profile: reader, maxHomeItems: 4))
        XCTAssertEqual(editor.draft, reader)
        XCTAssertNil(editor.mergeReport, "Loading the reader's layout is not a merge")
        XCTAssertNil(editor.snapshot)
        editor.reset()
        XCTAssertEqual(editor.draft, .defaults)
    }
}
