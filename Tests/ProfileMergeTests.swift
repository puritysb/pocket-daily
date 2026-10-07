import XCTest
@testable import Pocket

final class ProfileMergeTests: XCTestCase {
    private var base: PocketProfile { .defaults }

    @MainActor
    func testScopedPayloadsDiscardAndSaveKeepOtherAreasPending() {
        let editor = ProfileEditorState()
        editor.draft.home.weather = .off
        editor.draft.sleep.mode = .reader
        editor.reading.startupApp = 0
        editor.reading.sleepTimeoutMinutes = 20
        editor.reading.fontSize = 3
        editor.reading.orientation = .landscape
        let home = editor.profile(in: .home)
        XCTAssertEqual(home.home.weather, .off)
        XCTAssertEqual(home.sleep, editor.base.sleep)
        let reading = editor.preferences(in: .reading)
        XCTAssertEqual(reading.fontSize, 3)
        XCTAssertEqual(reading.orientation, .landscape)
        XCTAssertEqual(reading.startupApp, 1)
        XCTAssertEqual(reading.sleepTimeoutMinutes, 10)
        editor.syncReading(reading) // A successful Reading save updates only its baseline.
        XCTAssertTrue(editor.pending(in: .reading).isEmpty)
        XCTAssertEqual(editor.reading.startupApp, 0)
        XCTAssertEqual(editor.reading.sleepTimeoutMinutes, 20)
        editor.revert(.home)
        XCTAssertTrue(editor.pending(in: .home).isEmpty)
        XCTAssertFalse(editor.pending(in: .sleep).isEmpty)
        XCTAssertEqual(editor.reading.fontSize, 3)
        editor.sync(with: ReaderProfileState(deviceID: "1234ABCD", generation: 1,
                                             profile: editor.profile(in: .sleep), maxHomeItems: 4))
        XCTAssertEqual(editor.draft.sleep.mode, .reader)
        XCTAssertEqual(editor.reading.sleepTimeoutMinutes, 20)
    }

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
    @MainActor
    func testKnownDraftNeverMergesWithAnotherReader() async throws {
        let editor = ProfileEditorState()
        editor.sync(with: .init(deviceID: "1234ABCD", generation: 1, profile: .defaults, maxHomeItems: 4))
        editor.draft.home.weather = .top
        editor.reading.fontSize = 3
        let original = try XCTUnwrap(editor.snapshot)
        var other = PocketProfile.defaults
        other.sleep.mode = .reader
        editor.sync(with: .init(deviceID: "5678ABCD", generation: 8, profile: other, maxHomeItems: 4))
        editor.syncReading(ReaderPreferences(fontSize: 0))
        XCTAssertTrue(editor.targetMismatch)
        XCTAssertEqual(editor.draft, original.draft)
        XCTAssertEqual(editor.reading, original.reading)
        XCTAssertEqual(editor.base, original.base)
        XCTAssertFalse(editor.bindForApply(to: "5678ABCD"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileEditStore(url: directory.appendingPathComponent("profile.json"))
        try await editor.useDraft(with: "5678ABCD", store: store)
        XCTAssertFalse(editor.targetMismatch)
        XCTAssertEqual(editor.targetDeviceID, "5678ABCD")
        XCTAssertEqual(store.recoveredDrafts().first?.draft, original.draft)
        XCTAssertEqual(store.recoveredDrafts().first?.targetDeviceID, "1234ABCD")
    }

    @MainActor
    func testGenericDraftRequiresApplyAndRemembersReviewedTargetAcrossDisconnect() throws {
        let editor = ProfileEditorState()
        editor.draft.home.weather = .off
        editor.sync(with: .init(deviceID: "1234ABCD", generation: 1, profile: .defaults, maxHomeItems: 4))
        XCTAssertNil(editor.targetDeviceID)
        let saved = try XCTUnwrap(editor.snapshot)
        let reopened = ProfileEditorState()
        reopened.restore(saved)
        reopened.observeTarget(nil)
        reopened.observeTarget("5678ABCD")
        XCTAssertTrue(reopened.targetMismatch)
        XCTAssertFalse(reopened.bindForApply(to: "5678ABCD"))
        editor.observeTarget(nil)
        editor.observeTarget("1234ABCD")
        XCTAssertTrue(editor.bindForApply(to: "1234ABCD"))
        XCTAssertEqual(editor.snapshot?.targetDeviceID, "1234ABCD")
    }

    func testLegacySnapshotReadsAsGenericAndMalformedOriginalIsRecovered() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profile.json")
        let store = ProfileEditStore(url: url)
        var draft = base
        draft.home.weather = .off
        let snapshot = ProfileEditSnapshot(draft: draft, base: base, reading: ReaderPreferences(), readingBase: ReaderPreferences(), savedAt: Date())
        try store.save(snapshot)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "targetDeviceID")
        json.removeValue(forKey: "reviewDeviceID")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertNil(try store.loadChecked()?.targetDeviceID)
        let malformed = Data("broken original".utf8)
        try malformed.write(to: url)
        XCTAssertThrowsError(try store.loadChecked())
        try store.save(nil)
        let recovered = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovered.first)), malformed)
    }

    @MainActor
    func testRestoringAnotherDraftClearsPreviousConflictsAndConnectionState() throws {
        let editor = ProfileEditorState()
        editor.draft.home.weather = .top
        var incoming = PocketProfile.defaults
        incoming.home.weather = .off
        editor.sync(with: .init(deviceID: "1234ABCD", generation: 1, profile: incoming, maxHomeItems: 4))
        XCTAssertEqual(editor.mergeReport?.bothChanged, [.weather])
        let recovered = ProfileEditSnapshot(draft: incoming, base: incoming, baseGeneration: 1, reading: ReaderPreferences(), readingBase: ReaderPreferences(), savedAt: Date(), targetDeviceID: "1234ABCD")
        editor.observeTarget("5678ABCD")
        XCTAssertTrue(editor.targetMismatch)
        editor.restore(recovered)
        XCTAssertNil(editor.mergeReport)
        XCTAssertNil(editor.connectedDeviceID)
        XCTAssertFalse(editor.targetMismatch)
        editor.sync(with: .init(deviceID: "1234ABCD", generation: 1, profile: incoming, maxHomeItems: 4))
        XCTAssertNil(editor.mergeReport, "Identical reader baseline must not retain an unrelated recovered conflict")
        editor.useReader(in: .home)
        XCTAssertEqual(editor.draft, incoming)
    }

}
