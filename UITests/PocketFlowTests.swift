import XCTest

/// Guards the behaviour that App Review and a first-run user see before anything
/// is connected: no permission prompt at launch, and a demo mode that cannot
/// touch a device.
final class PocketFlowTests: XCTestCase {
    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// Creating a `CBCentralManager` or probing the LAN is what raises the
    /// Bluetooth and local-network prompts, so both are deferred until the user
    /// asks to connect. A prompt on a cold launch is the regression this guards.
    func testLaunchRequestsNoPermissions() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Reader profile"].waitForExistence(timeout: 10))
        // Give a prompt time to appear if one were going to.
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3),
                       "A permission prompt appeared at launch: \(springboard.alerts.firstMatch.label)")
        XCTAssertTrue(app.buttons["Find & Connect"].exists)
        XCTAssertTrue(app.buttons["Explore without a reader"].exists)
    }

    func testDirectConnectionRequiresConfirmationAndOfflinePreparationIsAvailable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Choose file…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Choose file…"].isEnabled)
        app.buttons["Connect directly"].tap()
        XCTAssertTrue(app.staticTexts["Connect to the reader’s temporary Wi-Fi?"].waitForExistence(timeout: 5))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Find & Connect"].isEnabled)
    }

    func testFilePickerStaysOpenWhileSearching() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Choose file…"].waitForExistence(timeout: 10))
        app.buttons["Choose file…"].tap()
        let search = app.searchFields.firstMatch
        // iPad collapses the system search field into a toolbar button.
        if !search.waitForExistence(timeout: 3) {
            let searchButton = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Search", "검색"])
            ).firstMatch
            XCTAssertTrue(searchButton.waitForExistence(timeout: 5))
            searchButton.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("pocket-search-check")
        // iPad's suggestion popover temporarily hides the field from accessibility.
        // Its suggestion still contains the query; a reopened picker loses both.
        let retainedQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@ OR label CONTAINS %@",
                        "pocket-search-check", "pocket-search-check")
        ).firstMatch
        XCTAssertTrue(retainedQuery.exists, "The picker lost the entered search")
        XCTAssertEqual(app.state, .runningForeground)
        let staysOpen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: retainedQuery
        )
        staysOpen.isInverted = true
        wait(for: [staysOpen], timeout: 5)
    }

    /// Demo mode is the path App Review uses without hardware. It must populate
    /// the interface while leaving every device-mutating control disabled.
    func testDemoModeIsPopulatedButCannotTransfer() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Reader profile"].waitForExistence(timeout: 10))

        app.buttons["Explore without a reader"].tap()

        XCTAssertTrue(app.staticTexts["Local demo · transfers disabled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Exit demo"].exists)
        // Settings are populated so the interface is reviewable...
        XCTAssertTrue(app.switches["Start on Pocket Daily"].exists)
        // ...but nothing may reach a device.
        XCTAssertFalse(app.buttons["Choose file…"].isEnabled)
        XCTAssertFalse(app.buttons["Demo preview only"].isEnabled)

        app.buttons["Exit demo"].tap()
        XCTAssertTrue(app.buttons["Explore without a reader"].waitForExistence(timeout: 5))
    }

    /// Discovery with no reader on the network must end in an actionable message, not
    /// an open-ended spinner. Probing a home subnet one small batch at a time took
    /// minutes and buried the user in timeouts; the sweep is now concurrent and
    /// bounded, so a miss resolves quickly.
    func testDiscoveryWithoutAReaderFailsQuicklyAndSaysWhatToDo() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Reader profile"].waitForExistence(timeout: 10))

        let started = Date()
        app.buttons["Find & Connect"].tap()

        let message = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", "No Pocket reader was visible")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 90), "Discovery never reported a result")

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 60, "Discovery took \(Int(elapsed))s to report that no reader was found")
    }

    /// The independent-project and privacy notices are a submission commitment,
    /// so they must be reachable from the shipping interface.
    func testAboutSheetStatesTheIndependenceAndPrivacyPosition() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Reader profile"].waitForExistence(timeout: 10))

        (app.buttons["About"].exists ? app.buttons["About"] : app.buttons["About & Privacy"]).tap()

        XCTAssertTrue(app.staticTexts["Independent project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Privacy"].exists)
        XCTAssertTrue(app.staticTexts["Firmware responsibility"].exists)
    }
}
