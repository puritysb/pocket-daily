import XCTest

/// Drives the shipping demo mode and captures the App Store screenshots from
/// the real interface as test attachments. `scripts/capture_screenshots.sh`
/// exports them from the result bundle and flattens them to opaque PNGs.
///
/// Both layouts open on Home & Sleep. The compact (iPhone) layout keeps the
/// reader controls in their own tab, so it earns a Reader shot; the wide
/// (iPad) layout already shows them beside the studio and shows X4 instead.
final class PocketScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureDemoScreens() throws {
        let app = launch(hardware: "X3")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        try save(name: "01-home-x3")

        app.openScreen("Sleep")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Daily Brief never rendered")
        try save(name: "02-sleep-x3")

        app.openScreen("Home")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never returned")
        app.openCards()
        XCTAssertTrue(app.waitForLayoutPreview(caption: "Card page"), "The card page never rendered")
        // Wide layouts show the canvas beside the card editor; compact ones scroll back to it.
        if app.isCompact { app.revealCanvas() }
        try save(name: "03-cards")

        if app.isCompact {
            app.open("Reader")
            XCTAssertTrue(app.buttons["Exit demo"].waitForExistence(timeout: 5))
            try save(name: "04-reader")
        } else {
            app.terminate()
            let x4 = launch(hardware: "X4")
            XCTAssertTrue(x4.waitForLayoutPreview(), "The X4 Home preview never rendered")
            try save(name: "04-home-x4")
        }
    }

    private func launch(hardware: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--hardware=\(hardware)"]
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
