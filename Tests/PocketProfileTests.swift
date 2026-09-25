import XCTest
@testable import Pocket

final class PocketProfileTests: XCTestCase {
    private let device = "5B09AF70"
    /// Captured from X3 firmware w15cb1e54 (GET /api/pocket/v1/profile after a save).
    private let readerResponse = #"{"schema":1,"deviceID":"5B09AF70","generation":1,"home":{"items":["study","reading","monitor"],"dailyWord":true,"weather":"top","nextEvent":false},"sleep":{"mode":"brief","sections":["weather","reading","study"]},"capabilities":{"homeItems":["reading","study","provider","monitor"],"maxHomeItems":4,"weather":["bottom","top","off"],"sleepModes":["brief","reader"],"sleepSections":["reading","study","weather","today"]}}"#

    func testDefaultsShowWhatAReaderWithoutAProfileShows() {
        let d = PocketProfile.defaults
        // The firmware default also lists provider, which only the retired daemon fed.
        XCTAssertEqual(d.home.items, [.reading, .study])
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
                       #"{"home":{"dailyWord":true,"items":["reading","study"],"nextEvent":true,"weather":"bottom"},"schema":1,"sleep":{"mode":"brief","sections":["reading","study","weather","today"]}}"#)
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

    func testTheReaderAdvertisesWhichItemsItAccepts() throws {
        // The captured v1 reader predates the daily word item and pinned card.
        let old = try ReaderProfileState.decode(Data(readerResponse.utf8), deviceID: device)
        XCTAssertEqual(old.homeItems, [.reading, .study, .provider, .monitor])
        XCTAssertEqual(old.sleepSections, [.reading, .study, .weather, .today])
        let newer = readerResponse
            .replacingOccurrences(of: #""homeItems":["reading","study","provider","monitor"]"#,
                                  with: #""homeItems":["reading","study","provider","monitor","word","future"]"#)
            .replacingOccurrences(of: #""sleepSections":["reading","study","weather","today"]"#,
                                  with: #""sleepSections":["reading","study","weather","today","card"]"#)
            .replacingOccurrences(of: #"["study","reading","monitor"]"#, with: #"["word","study"]"#)
            .replacingOccurrences(of: #"["weather","reading","study"]"#, with: #"["card","reading"]"#)
        let state = try ReaderProfileState.decode(Data(newer.utf8), deviceID: device)
        XCTAssertEqual(state.profile.home.items, [.word, .study])
        XCTAssertEqual(state.profile.sleep.sections, [.card, .reading])
        XCTAssertTrue(state.homeItems.contains(.word), "Known capabilities are offered; unknown names ignored")
        XCTAssertTrue(state.sleepSections.contains(.card))
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
    func testRetiredDaemonItemsAreDroppedOnLoadWithoutMarkingEdits() throws {
        let editor = ProfileEditorState()
        // readerResponse stores [study, reading, monitor].
        editor.sync(with: try ReaderProfileState.decode(Data(readerResponse.utf8), deviceID: device))
        XCTAssertEqual(editor.draft.home.items, [.study, .reading])
        XCTAssertFalse(editor.isDirty)
        var onlyRetired = PocketProfile.defaults
        onlyRetired.home.items = [.provider, .monitor]
        XCTAssertEqual(onlyRetired.withoutRetiredItems.home.items, [.reading], "Never empty")
    }

    @MainActor
    func testEditorKeepsUnsentEditsAndAdoptsCleanUpdates() throws {
        let editor = ProfileEditorState()
        let first = try ReaderProfileState.decode(Data(readerResponse.utf8), deviceID: device)
        editor.sync(with: first)
        XCTAssertEqual(editor.draft, first.profile.withoutRetiredItems)
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
