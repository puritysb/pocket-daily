import XCTest

/// Drives the shipping demo mode and captures the App Store screenshots from
/// the real interface as test attachments. `scripts/capture_screenshots.sh`
/// exports them from the result bundle and flattens them to opaque PNGs.
///
/// The app has two layouts and they need different shot lists. The compact
/// (iPhone) layout stacks the inspector below the reader preview, so it earns
/// its own screenshot. The wide (iPad/Mac) layout already shows the inspector
/// beside the preview, so a separate "inspector" shot would be byte-identical
/// to the first one.
final class PocketScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureDemoScreens() throws {
        let app = launch(hardware: "X3")
        XCTAssertTrue(app.staticTexts["Reader profile"].waitForExistence(timeout: 10))
        let isCompact = app.buttons["About"].exists

        try save(name: "01-profile-x3")

        if isCompact {
            app.swipeUp()
            app.swipeUp()
            XCTAssertTrue(app.staticTexts["DEVICE SETTINGS"].waitForExistence(timeout: 5))
            try save(name: "02-inspector")
            app.buttons["About"].tap()
            XCTAssertTrue(app.staticTexts["Independent project"].waitForExistence(timeout: 5))
            try save(name: "03-about")
        } else {
            app.buttons["About & Privacy"].tap()
            XCTAssertTrue(app.staticTexts["Independent project"].waitForExistence(timeout: 5))
            try save(name: "02-about")
        }
        app.terminate()

        let x4 = launch(hardware: "X4")
        XCTAssertTrue(x4.staticTexts["Reader profile"].waitForExistence(timeout: 10))
        try save(name: isCompact ? "04-profile-x4" : "03-profile-x4")
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
