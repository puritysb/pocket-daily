import XCTest
@testable import Pocket

final class PocketProfileTests: XCTestCase {
    private let device = "5B09AF70"
    /// Captured from X3 firmware w15cb1e54 (GET /api/pocket/v1/profile after a save).
    private let readerResponse = #"{"schema":1,"deviceID":"5B09AF70","generation":1,"home":{"items":["study","reading","monitor"],"dailyWord":true,"weather":"top","nextEvent":false},"sleep":{"mode":"brief","sections":["weather","reading","study"]},"capabilities":{"homeItems":["reading","study","provider","monitor"],"maxHomeItems":4,"weather":["bottom","top","off"],"sleepModes":["brief","reader"],"sleepSections":["reading","study","weather","today"]}}"#

    func testDefaultsMatchTheFirmwareDefaults() {
        let d = PocketProfile.defaults
        XCTAssertEqual(d.home.items, [.reading, .study, .provider])
        XCTAssertTrue(d.home.dailyWord)
        XCTAssertEqual(d.home.weather, .bottom)
        XCTAssertTrue(d.home.nextEvent)
        XCTAssertEqual(d.sleep.mode, .brief)
        XCTAssertEqual(d.sleep.sections, [.reading, .study, .weather, .today])
        XCTAssertNil(d.validationError)
    }

    func testRequestBodyHasExactlyTheKeysTheReaderAccepts() throws {
        let body = try PocketProfile.defaults.requestBody()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "home", "sleep"])
        XCTAssertEqual(json["schema"] as? Int, 1)
        XCTAssertEqual(Set((json["home"] as? [String: Any])?.keys ?? [:].keys), ["items", "dailyWord", "weather", "nextEvent"])
        XCTAssertEqual(Set((json["sleep"] as? [String: Any])?.keys ?? [:].keys), ["mode", "sections"])
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"home":{"dailyWord":true,"items":["reading","study","provider"],"nextEvent":true,"weather":"bottom"},"schema":1,"sleep":{"mode":"brief","sections":["reading","study","weather","today"]}}"#)
    }

    func testValidationMirrorsTheFirmwareRules() {
        var p = PocketProfile.defaults
        p.home.items = []
        XCTAssertNotNil(p.validationError)
        p.home.items = [.reading, .reading]
        XCTAssertNotNil(p.validationError)
        p.home.items = [.reading, .study, .provider, .monitor]
        XCTAssertNil(p.validationError)
        p.sleep.sections = []
        XCTAssertNotNil(p.validationError)
        p.sleep.sections = [.weather, .weather]
        XCTAssertNotNil(p.validationError)
    }

    func testDecodesTheReadersResponse() throws {
        let state = try ReaderProfileState.decode(Data(readerResponse.utf8), deviceID: device)
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(state.maxHomeItems, 4)
        XCTAssertEqual(state.profile.home.items, [.study, .reading, .monitor])
        XCTAssertEqual(state.profile.home.weather, .top)
        XCTAssertFalse(state.profile.home.nextEvent)
        XCTAssertEqual(state.profile.sleep.sections, [.weather, .reading, .study])
    }

    func testRejectsAnotherReaderASchemaChangeOrAnUnknownId() {
        XCTAssertThrowsError(try ReaderProfileState.decode(Data(readerResponse.utf8), deviceID: "00000000")) {
            XCTAssertEqual($0 as? ReaderProfileState.Failure, .identity)
        }
        let schema2 = readerResponse.replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#)
        XCTAssertThrowsError(try ReaderProfileState.decode(Data(schema2.utf8), deviceID: device)) {
            XCTAssertEqual($0 as? ReaderProfileState.Failure, .unsupportedSchema)
        }
        // A newer reader's item must not be silently dropped and sent back.
        let unknown = readerResponse.replacingOccurrences(of: #"["study","reading","monitor"]"#, with: #"["study","clock"]"#)
        XCTAssertThrowsError(try ReaderProfileState.decode(Data(unknown.utf8), deviceID: device)) {
            XCTAssertEqual($0 as? ReaderProfileState.Failure, .unknownValue)
        }
    }

    @MainActor
    func testEditorKeepsUnsentEditsAndAdoptsCleanUpdates() throws {
        let editor = ProfileEditorState()
        let first = try ReaderProfileState.decode(Data(readerResponse.utf8), deviceID: device)
        editor.sync(with: first)
        XCTAssertEqual(editor.draft, first.profile)
        XCTAssertFalse(editor.isDirty)

        editor.draft.home.weather = .off
        XCTAssertTrue(editor.isDirty)
        let newer = readerResponse.replacingOccurrences(of: #""generation":1"#, with: #""generation":2"#)
            .replacingOccurrences(of: #""nextEvent":false"#, with: #""nextEvent":true"#)
        editor.sync(with: try ReaderProfileState.decode(Data(newer.utf8), deviceID: device))
        XCTAssertEqual(editor.draft.home.weather, .off, "An unsent edit survives a reload")
        XCTAssertTrue(editor.base.home.nextEvent)
        editor.revert()
        XCTAssertEqual(editor.draft, editor.base)
        XCTAssertFalse(editor.isDirty)

        editor.sync(with: nil)
        XCTAssertEqual(editor.draft, .defaults, "Without a reader the editor starts from the original layout")
    }
}
