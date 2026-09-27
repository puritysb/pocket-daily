import XCTest

/// Two-device continuity through a real KOReader sync server. Runs only when
/// `scripts/e2e_sync.sh` provides a server and account (TEST_RUNNER_ variables);
/// the first test runs on one simulator and the second on another.
final class PocketSyncEndToEndTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(environment["KOSYNC_E2E_SERVER"] == nil, "Run through scripts/e2e_sync.sh")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fresh-library"]
        app.launchEnvironment["KOSYNC_E2E_SERVER"] = environment["KOSYNC_E2E_SERVER"]
        app.launch()
        return app
    }

    /// Signs in (creating the account the first time) on the given server.
    private func signIn(_ app: XCUIApplication) {
        app.openShelf("Books")
        app.buttons["library-sync"].tap()
        let signOut = app.buttons["Sign out"]
        if signOut.waitForExistence(timeout: 3) {
            // An account from an earlier run points at a server that is gone.
            signOut.tap()
            let confirm = app.sheets.buttons["Sign out"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
        }
        attach(app, "sync-sheet")
        let username = app.textFields["sync-username"]
        for _ in 0..<5 where !username.isHittable { app.swipeDown() }
        username.tap()
        username.typeText(environment["KOSYNC_E2E_USER"]!)
        let password = app.secureTextFields["sync-password"]
        password.tap()
        password.typeText(environment["KOSYNC_E2E_PASSWORD"]!)
        let create = app.buttons["sync-create"]
        for _ in 0..<5 where !create.isHittable { app.swipeUp() }
        create.tap()
        if !signOut.waitForExistence(timeout: 10) {
            // Already registered by the other device: sign in instead.
            app.buttons["sync-sign-in"].tap()
        }
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "The account was not accepted")
        attach(app, "sync-connected")
        app.buttons["Done"].tap()
    }

    private func openGuide(_ app: XCUIApplication) -> XCUIElement {
        let guide = app.buttons["book-Welcome to Pocket Daily"]
        XCTAssertTrue(guide.waitForExistence(timeout: 15))
        guide.tap()
        XCTAssertTrue(app.staticTexts["reader-progress"].waitForExistence(timeout: 20))
        return app.descendants(matching: .any)["reader-page"]
    }

    private func percent(_ app: XCUIApplication) -> Int {
        Int(app.staticTexts["reader-progress"].label.filter(\.isNumber)) ?? -1
    }

    /// Device A reads to the third chapter and closes the book, which uploads.
    func test1ReadAndUpload() {
        let app = launch()
        signIn(app)
        let page = openGuide(app)
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Contents"].tap()
        app.buttons["Continue on your reader"].tap()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.percent(app) > 20 }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 10), .completed)
        attach(app, "device-a-position")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["reader-close"].tap()
        XCTAssertTrue(app.buttons["continue-reading"].waitForExistence(timeout: 10))
        // The upload runs as the reader closes.
        Thread.sleep(forTimeInterval: 3)
    }

    /// Device B opens the same book at the start and is offered device A's place.
    func test2OfferedAndJump() {
        let app = launch()
        signIn(app)
        _ = openGuide(app)
        let go = app.buttons["reader-sync-go"]
        XCTAssertTrue(go.waitForExistence(timeout: 20), "No continuation was offered")
        attach(app, "device-b-offer")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Pocket Daily")).firstMatch.exists)
        go.tap()
        let jumped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.percent(app) > 20 }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [jumped], timeout: 10), .completed, "The jump did not move the page")
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "X3 or X4")).firstMatch
            .waitForExistence(timeout: 10), "The jump did not land in the uploaded chapter")
        attach(app, "device-b-jumped")
    }
}
