import XCTest

/// Drives the shipping app and captures the App Store screenshots from the
/// real interface as test attachments. `scripts/capture_screenshots.sh`
/// exports them from the result bundle and flattens them to opaque PNGs.
///
/// Reading comes first: the bundled guide open in the reader, then the
/// Library. The companion follows in demo mode: Home & Sleep, My cards, and
/// Device management. Wide layouts also show the X4 Home.
final class PocketScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Chrome must stay operable when its labels scale up. This QA capture is
    /// deliberately excluded from the numbered App Store screenshot set.
    func testCaptureAccessibleLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--ui-test-fresh-library",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let add = app.buttons["library-add"]
        let settings = app.buttons["app-settings"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        XCTAssertTrue(add.isHittable, "Add books must remain reachable with large text")
        XCTAssertTrue(settings.isHittable, "Settings must remain reachable with large text")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "qa-accessibility-library"
        attachment.lifetime = .keepAlways
        self.add(attachment)
        add.tap()
        XCTAssertTrue(app.buttons["library-import"].waitForExistence(timeout: 5))
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
        let page = app.descendants(matching: .any)["reader-page"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Ready"), object: page)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 20), .completed, "The book is still loading")
        try save(name: "01-reading")
        let middle = app.descendants(matching: .any)["reader-page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.tap()
        let close = app.buttons["reader-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["continue-reading"].waitForExistence(timeout: 10))
        try save(name: "02-library")

        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        try save(name: "03-home-x3")

        app.openCards()
        XCTAssertTrue(app.waitForCardPreview(), "The card page never rendered")
        // Wide layouts show the canvas beside the card editor; compact ones scroll back to it.
        app.revealCanvas()
        try save(name: "04-cards")
        app.buttons["content-editor-close"].tap()

        if app.isCompact {
            app.open("Device")
            XCTAssertTrue(app.buttons["Exit demo"].waitForExistence(timeout: 5))
            try save(name: "05-device")
        } else {
            app.terminate()
            let x4 = launch(hardware: "X4")
            x4.open("Screens")
            XCTAssertTrue(x4.waitForLayoutPreview(), "The X4 Home preview never rendered")
            try save(name: "05-home-x4")
            x4.open("Device")
            try save(name: "07-device")
        }
    }

    func testCaptureArticleInbox() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-feeds=store-screenshots-\(UUID().uuidString)", "--ui-test-fresh-library"]
        app.launch()
        app.openShelf("Articles")
        app.openSubscriptions()
        let input = app.textFields["feed-url"]
        input.tap(); input.typeText("https://journal.example/feed.xml")
        app.buttons["feed-subscribe"].tap()
        XCTAssertTrue(app.buttons["unsubscribe-The Quiet Journal"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Read The books we return to"].waitForExistence(timeout: 5))
        app.buttons["article-options-The books we return to"].tap()
        app.buttons["Save for later"].tap()
        app.filterArticles("All articles")
        try save(name: "06-articles")
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
