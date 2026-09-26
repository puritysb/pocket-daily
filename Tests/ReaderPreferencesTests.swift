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
}
