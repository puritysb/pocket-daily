import XCTest

@testable import Pocket

/// The preferences document the reader serves and accepts
/// (`/api/pocket/v1/preferences`), including the optional button keys.
final class ReaderPreferencesTests: XCTestCase {
    private func decode(_ json: String) throws -> ReaderPreferences {
        try ReaderPreferences.decode(Data(json.utf8))
    }

    private func body(_ preferences: ReaderPreferences) throws -> [String: Int] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: preferences.requestBody()) as? [String: Int])
    }

    func testOlderReaderOmitsButtonSettingsAndTheyAreNeverSent() throws {
        let preferences = try decode(#"{"startupApp":1,"pocketDailySleepCover":0,"sleepTimeoutMinutes":10,"fontSize":2}"#)
        XCTAssertEqual(preferences.fontSize, 2)
        XCTAssertFalse(preferences.pocketDailySleepCover)
        XCTAssertNil(preferences.sideButtons)
        XCTAssertNil(preferences.frontButtonsFollowOrientation)
        XCTAssertFalse(preferences.hasButtonSettings)
        XCTAssertEqual(Set(try body(preferences).keys),
                       ["startupApp", "pocketDailySleepCover", "sleepTimeoutMinutes", "fontSize"])
    }

    func testButtonSettingsRoundTrip() throws {
        var preferences = try decode(#"""
        {"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":31,"fontSize":1,
         "sideButtonLayout":1,"frontButtonFollowOrientation":1}
        """#)
        XCTAssertEqual(preferences.sideButtons, .nextPrevious)
        XCTAssertEqual(preferences.frontButtonsFollowOrientation, true)
        XCTAssertTrue(preferences.hasButtonSettings)
        preferences.sideButtons = .off
        preferences.frontButtonsFollowOrientation = false
        let sent = try body(preferences)
        XCTAssertEqual(sent["sideButtonLayout"], 2)
        XCTAssertEqual(sent["frontButtonFollowOrientation"], 0)
        XCTAssertEqual(sent["sleepTimeoutMinutes"], 31)
    }

    /// A value this app does not know hides the control so it is never
    /// overwritten with a guess.
    func testUnknownButtonValuesAreNotOffered() throws {
        let preferences = try decode(#"""
        {"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":1,
         "sideButtonLayout":3,"frontButtonFollowOrientation":2}
        """#)
        XCTAssertNil(preferences.sideButtons)
        XCTAssertNil(preferences.frontButtonsFollowOrientation)
        XCTAssertEqual(Set(try body(preferences).keys).count, 4)
    }

    func testWakeIndicatorRoundTripAndLegacyCapability() throws {
        for value in [0, 1, 2] {
            let preferences = try decode("{\"startupApp\":1,\"pocketDailySleepCover\":1,\"sleepTimeoutMinutes\":10,\"fontSize\":1,\"sleepWakeIndicator\":\(value)}")
            XCTAssertEqual(preferences.sleepWakeIndicator, value < 2 ? value == 1 : nil)
            XCTAssertEqual(try body(preferences)["sleepWakeIndicator"], value < 2 ? value : nil)
        }
        XCTAssertNil(try decode(#"{"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":1}"#).sleepWakeIndicator)
    }

    @MainActor
    func testWakeDraftMergesOnlyWhenSupportedAndCanBeDiscarded() {
        let editor = ProfileEditorState()
        editor.reading.sleepWakeIndicator = false
        let supported = ReaderPreferences(sleepWakeIndicator: true)
        editor.syncReading(supported)
        XCTAssertEqual(editor.reading.sleepWakeIndicator, false)
        XCTAssertTrue(editor.readingDirty)
        editor.revert()
        XCTAssertEqual(editor.reading.sleepWakeIndicator, true)
        editor.reading.sleepWakeIndicator = false
        editor.syncReading(ReaderPreferences())
        XCTAssertNil(editor.reading.sleepWakeIndicator)
        XCTAssertFalse(editor.readingDirty)
        let model = PocketModel()
        model.preferences = ReaderPreferences()
        model.stageReadingPreferences(ReaderPreferences(sleepWakeIndicator: false))
        XCTAssertNil(model.preferences?.sleepWakeIndicator)
        XCTAssertFalse(model.preferencesDirty)
    }

    func testMalformedDocumentIsRejected() {
        XCTAssertThrowsError(try decode(#"{"startupApp":"1","pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":1}"#))
        XCTAssertThrowsError(try decode(#"{"startupApp":1}"#))
        XCTAssertThrowsError(try decode("not json"))
    }

    @MainActor
    func testButtonSettersRequireAReaderThatReportsThem() {
        let model = PocketModel()
        model.preferences = ReaderPreferences()
        model.setSideButtons(.off)
        model.setFrontButtonsFollowOrientation(true)
        XCTAssertNil(model.preferences?.sideButtons)
        XCTAssertFalse(model.preferencesDirty)

        model.preferences = ReaderPreferences(sideButtons: .previousNext, frontButtonsFollowOrientation: false)
        model.setSideButtons(.nextPrevious)
        XCTAssertEqual(model.preferences?.sideButtons, .nextPrevious)
        XCTAssertTrue(model.preferencesDirty)
    }
    @MainActor
    func testOfflineReadingEditsMergeWithReaderWithoutOverwritingUntouchedFields() {
        let editor = ProfileEditorState()
        editor.reading.fontSize = 3
        editor.reading.sideButtons = .nextPrevious
        var loaded = ReaderPreferences(sideButtons: .previousNext, frontButtonsFollowOrientation: true)
        loaded.sleepTimeoutMinutes = 20
        editor.syncReading(loaded)
        XCTAssertEqual(editor.reading.fontSize, 3)
        XCTAssertEqual(editor.reading.sideButtons, .nextPrevious)
        XCTAssertEqual(editor.reading.sleepTimeoutMinutes, 20)
        XCTAssertEqual(editor.reading.frontButtonsFollowOrientation, true)
        editor.syncReading(nil)
        XCTAssertTrue(editor.readingDirty)
        editor.revert()
        XCTAssertEqual(editor.reading, loaded)
        XCTAssertFalse(editor.readingDirty)
    }

    @MainActor
    func testUnsupportedSettingsAreNotSentAndSavedDraftBecomesBaseline() {
        let editor = ProfileEditorState()
        editor.reading.sideButtons = .off
        editor.syncReading(ReaderPreferences())
        XCTAssertNil(editor.reading.sideButtons)
        let model = PocketModel()
        model.preferences = ReaderPreferences()
        var draft = ReaderPreferences(sideButtons: .nextPrevious, frontButtonsFollowOrientation: true)
        draft.fontSize = 2
        model.stageReadingPreferences(draft)
        XCTAssertNil(model.preferences?.sideButtons)
        XCTAssertNil(model.preferences?.frontButtonsFollowOrientation)
        XCTAssertEqual(model.preferences?.fontSize, 2)
        editor.acceptReading(model.preferences)
        XCTAssertFalse(editor.readingDirty)
    }

}

final class ReaderFileValidationTests: XCTestCase {
    func testValidPageAndIdentityBoundary() throws {
        let page = ReaderFilePage(deviceID: "reader-a", path: "/Books", entries: [.init(name: "book.epub", directory: false, size: 100, deletable: true)], nextCursor: 128)
        XCTAssertNoThrow(try page.validate(identity: "reader-a", folder: "/Books", cursor: 0))
        XCTAssertThrowsError(try page.validate(identity: "reader-b", folder: "/Books", cursor: 0))
        XCTAssertThrowsError(try page.validate(identity: "reader-a", folder: "/", cursor: 0))
        XCTAssertThrowsError(try page.validate(identity: "reader-a", folder: "/Books", cursor: 128))
    }
    func testMalformedEntryCannotBecomeDeletePath() {
        for name in ["../book", ".cache", "folder/book", "%2e%2e", "bad\nname"] {
            let page = ReaderFilePage(deviceID: "a", path: "/", entries: [.init(name: name, directory: false, size: 1, deletable: true)], nextCursor: 0)
            XCTAssertThrowsError(try page.validate(identity: "a", folder: "/", cursor: 0))
        }
    }
}

@MainActor
final class ReaderFileDeletionIdentityTests: XCTestCase {
    func testConfirmationForAnotherReaderDoesNotStartWork() throws {
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO())
        defer { model.pauseForBackground() }
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"X3","deviceID":"reader-b","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"readerFiles":1}"#.utf8))
        model.deleteReaderFile("/book.epub", size: 100, folder: "/", identity: "reader-a")
        XCTAssertFalse(model.isWorking)
        model.deleteReaderFile("/book.epub", size: 100, folder: "/", identity: nil)
        XCTAssertFalse(model.isWorking)
    }
}
