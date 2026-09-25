import XCTest
@testable import Pocket

final class ReaderDisplayStateTests: XCTestCase {
    private let device = "5B09AF70"

    private func body(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var page: [String: Any] = ["sidePadding": 20, "topPadding": 5, "spacing": 16, "title": "포켓",
                                   "empty": "비어 있음", "labels": ["뒤로", "", "이전", "다음"]]
        var root: [String: Any] = ["schema": 1, "deviceID": device, "theme": "lyra", "orientation": 2,
                                   "font": ["family": "PocketSansWorld", "pointSize": 12], "contentPage": page]
        change(&root)
        if let replaced = root["contentPage"] as? [String: Any] { page = replaced }
        root["contentPage"] = page
        return try! JSONSerialization.data(withJSONObject: root)
    }

    func testDecodesTheReadersResolvedInputs() throws {
        let state = try ReaderDisplayState.decode(body(), deviceID: device)
        XCTAssertEqual(state.theme, "lyra")
        XCTAssertEqual(state.orientation, .inverted)
        XCTAssertEqual(state.contentPage.spacing, 16)
        XCTAssertEqual(state.contentPage.labels, ["뒤로", "", "이전", "다음"])
        XCTAssertTrue(state.matchesPreviewFont)
    }

    func testRejectsAnotherReaderOrUnknownSchema() {
        XCTAssertThrowsError(try ReaderDisplayState.decode(body(), deviceID: "00000000")) {
            XCTAssertEqual($0 as? ReaderDisplayState.Failure, .identity)
        }
        XCTAssertThrowsError(try ReaderDisplayState.decode(body { $0["schema"] = 2 }, deviceID: device)) {
            XCTAssertEqual($0 as? ReaderDisplayState.Failure, .unsupportedSchema)
        }
        XCTAssertThrowsError(try ReaderDisplayState.decode(Data("{".utf8), deviceID: device)) {
            XCTAssertEqual($0 as? ReaderDisplayState.Failure, .malformed)
        }
    }

    func testRejectsValuesTheHostRendererCouldNotDrawExactly() {
        let cases: [(inout [String: Any]) -> Void] = [
            { $0["orientation"] = 4 },
            { $0["contentPage"] = ["sidePadding": -1, "topPadding": 5, "spacing": 16, "title": "t", "empty": "e",
                                   "labels": ["a", "b", "c", "d"]] },
            { $0["contentPage"] = ["sidePadding": 20, "topPadding": 5, "spacing": 16, "title": String(repeating: "x", count: 64),
                                   "empty": "e", "labels": ["a", "b", "c", "d"]] },
            { $0["contentPage"] = ["sidePadding": 20, "topPadding": 5, "spacing": 16, "title": "t", "empty": "e",
                                   "labels": ["a", "b", "c"]] },
        ]
        for change in cases {
            XCTAssertThrowsError(try ReaderDisplayState.decode(body(change), deviceID: device)) {
                XCTAssertEqual($0 as? ReaderDisplayState.Failure, .outOfRange)
            }
        }
    }

    func testReaderStyleDrivesOptionsAndOrientation() throws {
        let state = try ReaderDisplayState.decode(body(), deviceID: device)
        let style = PreviewStyle(reader: state)
        XCTAssertEqual(style.options.spacing, 16)
        XCTAssertEqual(style.options.labels, ["뒤로", "", "이전", "다음"])
        XCTAssertEqual(style.options.emptyTitle, "포켓")
        let request = ContentPreviewRequest(card: nil, image: nil, hardware: .x3, orientation: .portrait, style: style)
        XCTAssertEqual(request.effectiveOrientation, .inverted, "The reader's orientation wins over the local picker")
        XCTAssertEqual(style.source, .reader(theme: "lyra", fontMatches: true))
    }

    func testDifferentInstalledFontSizeIsReportedNotHidden() throws {
        let state = try ReaderDisplayState.decode(body { $0["font"] = ["family": "PocketSansWorld", "pointSize": 14] },
                                                  deviceID: device)
        XCTAssertFalse(state.matchesPreviewFont)
        XCTAssertTrue(PreviewStyle(reader: state).caption.contains("font size differs"))
    }

    func testReferenceMatchesTheDefaultDeviceThemeAndIsLabelled() {
        let reference = PreviewStyle.reference
        XCTAssertEqual(reference.options.sidePadding, 20)
        XCTAssertEqual(reference.options.topPadding, 5)
        XCTAssertEqual(reference.options.spacing, 16, "Lyra is the firmware default (LyraTheme.h)")
        XCTAssertNil(reference.orientation)
        XCTAssertTrue(reference.caption.hasPrefix("Default theme"))
        let request = ContentPreviewRequest(card: nil, image: nil, hardware: .x4, orientation: .clockwise)
        XCTAssertEqual(request.effectiveOrientation, .clockwise)
        XCTAssertEqual(request.style, .reference)
    }
}
