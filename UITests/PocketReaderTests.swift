import XCTest

/// The in-app reader works without any reader device: the Library opens first,
/// the bundled guide opens full screen, pages turn from taps, and the text
/// settings apply without leaving the page.
final class PocketReaderTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func progress(_ app: XCUIApplication) -> String {
        app.staticTexts["reader-progress"].label
    }

    func testWelcomeBookOpensTurnsPagesAndRemembersPosition() {
        let app = XCUIApplication()
        app.launch()
        app.openShelf("Books")
        let book = app.buttons["book-Welcome to Pocket Daily"]
        XCTAssertTrue(book.waitForExistence(timeout: 15), "The welcome book was not added to the library")
        attach(app, "library")
        book.tap()

        let page = app.descendants(matching: .any)["reader-page"]
        XCTAssertTrue(app.staticTexts["reader-progress"].waitForExistence(timeout: 20), "The reader never opened")
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Pocket Daily")).firstMatch
            .waitForExistence(timeout: 20), "The first page never rendered")
        attach(app, "reader-first-page")

        XCTAssertFalse(app.buttons["reader-close"].exists, "Books open straight to the page")
        let right = page.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let middle = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Earlier runs keep their position; start from the first chapter.
        middle.tap()
        let contents = app.buttons["Contents"]
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        contents.tap()
        let first = app.buttons["A quiet place to read"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "Contents lists the chapters")
        first.tap()
        XCTAssertFalse(app.buttons["reader-close"].waitForExistence(timeout: 2))
        let start = progress(app)
        // Two turns keep the short guide unfinished, so the Library offers to continue.
        for _ in 0..<2 { right.tap() }
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.progress(app) != start }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 10), .completed, "Tapping the right edge did not turn pages")
        let turned = progress(app)
        attach(app, "reader-turned")

        middle.tap()
        XCTAssertTrue(app.buttons["reader-appearance"].waitForExistence(timeout: 5), "A middle tap shows the controls")
        app.buttons["reader-appearance"].tap()
        let larger = app.buttons["Larger text"]
        XCTAssertTrue(larger.waitForExistence(timeout: 5))
        larger.tap()
        app.buttons["Night"].tap()
        attach(app, "reader-appearance")
        app.buttons["Paper"].tap()
        app.buttons["Smaller text"].tap()
        app.swipeDown(velocity: .fast)

        app.buttons["reader-close"].tap()
        let continueCard = app.buttons["continue-reading"]
        XCTAssertTrue(continueCard.waitForExistence(timeout: 10), "The library does not offer to continue")
        continueCard.tap()
        XCTAssertTrue(app.staticTexts["reader-progress"].waitForExistence(timeout: 20))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.progress(app) != "0%" }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [restored], timeout: 10), .completed,
                       "Reopening lost the position (was \(turned))")
        middle.tap()
        XCTAssertTrue(app.buttons["reader-close"].waitForExistence(timeout: 5))
        app.buttons["reader-close"].tap()
    }
}
