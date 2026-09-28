import XCTest

final class PocketArticleFeedTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSubscriptionsOfflineReadingSavingAndDeletionSurviveRefresh() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-feeds=\(UUID().uuidString)", "--ui-test-fresh-library"]
        app.launch()
        app.openShelf("Articles")
        app.openSubscriptions()
        let input = app.textFields["feed-url"]
        input.tap(); input.typeText("https://journal.example/feed.xml")
        app.buttons["feed-subscribe"].tap()
        XCTAssertTrue(app.buttons["unsubscribe-The Quiet Journal"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        let title = "A little room for a slower morning"
        let row = app.buttons["Read " + title]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Link only · get full text"].exists)
        app.buttons["article-options-" + title].tap()
        app.buttons["Save for later"].tap()
        app.filterArticles("Saved articles")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.webViews.staticTexts[title].waitForExistence(timeout: 20))
        let page = app.descendants(matching: .any)["reader-page"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Ready"), object: page)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 20), .completed)
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["reader-close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.openSubscriptions()
        app.buttons["unsubscribe-The Quiet Journal"].tap()
        app.buttons["Unsubscribe"].firstMatch.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Unsubscribing removed a saved article")
        app.terminate(); app.launch()
        app.openShelf("Articles"); app.filterArticles("Saved articles")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Saved/read state was lost after relaunch")
        app.buttons["article-options-" + title].tap()
        app.buttons["Delete"].tap()
        app.buttons["Delete " + title].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [removed], timeout: 5), .completed)
        app.openSubscriptions()
        input.tap(); input.typeText("https://journal.example/feed.xml")
        app.buttons["feed-subscribe"].tap()
        XCTAssertTrue(app.buttons["unsubscribe-The Quiet Journal"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.buttons["article-refresh"].tap()
        app.filterArticles("All articles")
        XCTAssertTrue(app.buttons["Read Notes from a familiar walk"].waitForExistence(timeout: 10))
        XCTAssertFalse(row.exists, "Refresh resurrected a deleted article")
    }

    func testInvalidFeedAndDemoSubscriptionControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-feeds=\(UUID().uuidString)"]
        app.launch(); app.openShelf("Articles"); app.openSubscriptions()
        let input = app.textFields["feed-url"]
        input.tap(); input.typeText("http://example.org/feed")
        app.buttons["feed-subscribe"].tap()
        XCTAssertTrue(app.staticTexts["feed-error"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments.append("--demo")
        app.launch(); app.openShelf("Articles"); app.openSubscriptions()
        input.tap(); input.typeText("https://journal.example/feed.xml")
        XCTAssertFalse(app.buttons["feed-subscribe"].isEnabled)
    }
}
