import XCTest

/// Drives the shipping app and captures the App Store screenshots from the
/// real interface as test attachments. `scripts/capture_screenshots.sh`
/// exports them from the result bundle and flattens them to opaque PNGs.
///
/// Reading comes first: the bundled guide open in the reader, then the
/// Library. The companion follows in demo mode: Home & Sleep, My cards, and
/// the Reader tab (compact) or the X4 Home (wide, where the Reader controls
/// already sit beside the studio).
final class PocketScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureDemoScreens() throws {
        let app = launch(hardware: "X3")
        app.openShelf("Books")
        let guide = app.buttons["book-Welcome to Pocket Daily"]
        XCTAssertTrue(guide.waitForExistence(timeout: 15))
        guide.tap()
        XCTAssertTrue(app.staticTexts["reader-progress"].waitForExistence(timeout: 20), "The reader never opened")
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "paper-like")).firstMatch
            .waitForExistence(timeout: 20), "The guide's first page never rendered")
        try save(name: "01-reading")
        let middle = app.descendants(matching: .any)["reader-page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.tap()
        let close = app.buttons["reader-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["continue-reading"].waitForExistence(timeout: 10))
        try save(name: "02-library")

        app.open("Customize reader")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        try save(name: "03-home-x3")

        app.openCards()
        XCTAssertTrue(app.waitForLayoutPreview(caption: "Card page"), "The card page never rendered")
        // Wide layouts show the canvas beside the card editor; compact ones scroll back to it.
        if app.isCompact { app.revealCanvas() }
        try save(name: "04-cards")

        if app.isCompact {
            app.open("Reader")
            XCTAssertTrue(app.buttons["Exit demo"].waitForExistence(timeout: 5))
            try save(name: "05-reader")
        } else {
            app.terminate()
            let x4 = launch(hardware: "X4")
            x4.open("Customize reader")
            XCTAssertTrue(x4.waitForLayoutPreview(), "The X4 Home preview never rendered")
            try save(name: "05-home-x4")
        }
    }

    private func launch(hardware: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--hardware=\(hardware)", "--ui-test-fresh-library"]
        app.launch()
        return app
    }

    private func save(name: String) throws {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
