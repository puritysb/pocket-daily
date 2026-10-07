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

    func testPhysicalPageKeyLabelsMatchFirmwareOrientationPolicy() {
        for orientation in ReaderPreferences.Orientation.allCases {
            for follow in [false, true] {
                for layout in ReaderPreferences.SideButtons.allCases {
                    let preferences = ReaderPreferences(orientation: orientation, sideButtons: layout,
                                                        frontButtonsFollowOrientation: follow)
                    let actions = preferences.sideButtonActions
                    if layout == .off {
                        XCTAssertEqual(actions.first, "No page turn")
                        XCTAssertEqual(actions.second, "No page turn")
                    } else {
                        let rotated = follow && (orientation == .inverted || orientation == .landscapeReversed)
                        let firstIsNext = (layout == .nextPrevious) != rotated
                        XCTAssertEqual(actions.first, firstIsNext ? "Next page" : "Previous page")
                        XCTAssertEqual(actions.second, firstIsNext ? "Previous page" : "Next page")
                    }
                }
            }
        }
    }

    func testReadingLayoutRoundTripsAllOrientationsAndBounds() throws {
        for direction in 0...3 {
            for margin in [5, 40] {
                let p = try decode("{\"startupApp\":1,\"pocketDailySleepCover\":1,\"sleepTimeoutMinutes\":10,\"fontSize\":1,\"orientation\":\(direction),\"lineSpacing\":3,\"screenMargin\":\(margin)}")
                XCTAssertEqual(try body(p)["orientation"], direction)
                XCTAssertEqual(try body(p)["lineSpacing"], 3)
                XCTAssertEqual(try body(p)["screenMargin"], margin)
            }
        }
        for value in [-1, 4, 255] {
            let p = try decode("{\"startupApp\":1,\"pocketDailySleepCover\":1,\"sleepTimeoutMinutes\":10,\"fontSize\":1,\"orientation\":\(value),\"lineSpacing\":\(value),\"screenMargin\":\(value)}")
            XCTAssertNil(p.orientation)
            XCTAssertNil(p.lineSpacing)
            XCTAssertNil(p.screenMargin)
            XCTAssertEqual(try body(p).count, 4)
        }
    }

    func testReadingLayoutMergesOfflineEditsAndDropsUnsupportedFields() {
        let base = ReaderPreferences(orientation: .portrait, lineSpacing: .normal, screenMargin: 5)
        var mine = base
        mine.orientation = .landscape
        var reader = base
        reader.lineSpacing = .wide
        let result = ProfileMerge.merge(base: base, mine: mine, reader: reader)
        XCTAssertEqual(result.preferences.orientation, .landscape)
        XCTAssertEqual(result.preferences.lineSpacing, .wide)
        XCTAssertEqual(ProfileMerge.pending(preferences: result.preferences, reader: reader), [.orientation])
        let legacy = ProfileMerge.merge(base: base, mine: mine, reader: ReaderPreferences()).preferences
        XCTAssertNil(legacy.orientation)
        XCTAssertNil(legacy.lineSpacing)
        XCTAssertNil(legacy.screenMargin)
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
        XCTAssertNil(model.preferences?.orientation)
        XCTAssertNil(model.preferences?.lineSpacing)
        XCTAssertNil(model.preferences?.screenMargin)
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
        var draft = ReaderPreferences(orientation: .landscape, lineSpacing: .wide, screenMargin: 20,
                                      sideButtons: .nextPrevious, frontButtonsFollowOrientation: true)
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
    func testPageKeyActionsForEveryOrientationLayoutAndRotationPolicy() {
        for orientation in ReaderPreferences.Orientation.allCases {
            for layout in ReaderPreferences.SideButtons.allCases {
                for follows in [false, true] {
                    let preferences = ReaderPreferences(orientation: orientation, sideButtons: layout, frontButtonsFollowOrientation: follows)
                    let reversed = follows && (orientation == .inverted || orientation == .landscapeReversed)
                    let swapped = (layout == .nextPrevious) != reversed
                    let actions = preferences.sideButtonActions
                    let expected = layout == .off ? ["No page turn", "No page turn"] : swapped ? ["Next page", "Previous page"] : ["Previous page", "Next page"]
                    XCTAssertEqual([actions.first, actions.second], expected, "\(orientation), \(layout), follows=\(follows)")
                }
            }
        }
    }

    func testPhysicalKeysRemainModelSpecific() {
        let x3 = ReaderButtonLayout(hardware: .x3)
        let x4 = ReaderButtonLayout(hardware: .x4)
        XCTAssertEqual(x3.firstKey, "Left edge")
        XCTAssertEqual(x3.secondKey, "Right edge")
        XCTAssertEqual(x3.frontControls, "Two front rocker controls")
        XCTAssertEqual(x4.firstKey, "Upper right-edge key")
        XCTAssertEqual(x4.secondKey, "Lower right-edge key")
        XCTAssertEqual(x4.frontControls, "Four front keys")
        XCTAssertNotEqual(x3.powerKey, x4.powerKey)
        XCTAssertEqual(x3.firstKeyPanelY, 194)
        XCTAssertEqual(x3.secondKeyPanelY, 194)
        XCTAssertEqual(x3.panelHeight, 792)
        XCTAssertEqual(x4.firstKeyPanelY, 385)
        XCTAssertEqual(x4.secondKeyPanelY, 465)
        XCTAssertEqual(x4.panelHeight, 800)
    }

    func testRequiredPreferenceBoundariesAndMalformedValues() throws {
        let valid: [String: Int] = ["startupApp": 1, "pocketDailySleepCover": 1, "sleepTimeoutMinutes": 10, "fontSize": 1]
        let cases: [(String, [Int])] = [
            ("startupApp", [-1, 2]), ("pocketDailySleepCover", [-1, 2]),
            ("sleepTimeoutMinutes", [0, 32]), ("fontSize", [-1, 4]),
        ]
        for (field, values) in cases {
            for invalid in values {
                var body = valid
                body[field] = invalid
                XCTAssertThrowsError(try ReaderPreferences.decode(JSONSerialization.data(withJSONObject: body)), "\(field)=\(invalid)")
            }
        }
        for minutes in [1, 31] {
            var body = valid
            body["sleepTimeoutMinutes"] = minutes
            body["fontSize"] = minutes == 1 ? 0 : 3
            body["startupApp"] = minutes == 1 ? 0 : 1
            XCTAssertNoThrow(try ReaderPreferences.decode(JSONSerialization.data(withJSONObject: body)))
        }
        XCTAssertThrowsError(try ReaderPreferences(fontSize: 4).requestBody())
        XCTAssertThrowsError(try ReaderPreferences(screenMargin: 41).requestBody())
    }

    func testOneOptionalButtonCapabilityDoesNotImplyTheOther() throws {
        let body: [String: Int] = ["startupApp": 1, "pocketDailySleepCover": 1, "sleepTimeoutMinutes": 10, "fontSize": 1, "sideButtonLayout": 1]
        let preferences = try ReaderPreferences.decode(JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(preferences.sideButtons, .nextPrevious)
        XCTAssertNil(preferences.frontButtonsFollowOrientation)
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: preferences.requestBody()) as? [String: Int])
        XCTAssertEqual(sent["sideButtonLayout"], 1)
        XCTAssertNil(sent["frontButtonFollowOrientation"])
    }

}
