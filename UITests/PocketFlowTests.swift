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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Home & Sleep opens first and redraws the firmware layout for each edit;
    /// demo never enables Send.
    func testHomeAndSleepEditorPreviewsEditsInDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--hardware=X3"]
        app.launch()
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        let top = app.buttons["Top"]
        app.revealInStudio(top)
        top.tap()
        XCTAssertTrue(app.waitForLayoutPreview(), "The weather edit was not redrawn")
        XCTAssertFalse(app.buttons["profile-send"].isEnabled)
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled)

        let readerSleep = app.buttons["Reader's sleep screen"]
        app.revealInStudio(readerSleep)
        readerSleep.tap()
        // A sleep edit shows the sleep surface; the reader's own screen is an outline.
        XCTAssertTrue(app.waitForLayoutPreview(caption: "Layout outline"))
        XCTAssertTrue(app.buttons["Sleep"].isSelected)
        let brief = app.buttons["Daily Brief"]
        brief.tap()
        XCTAssertTrue(app.waitForLayoutPreview(), "The Daily Brief was not drawn")
        attach(app, "home-sleep-editor")

        app.buttons["profile-revert"].tap()
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
    }

    /// My cards are edited in Home & Sleep; editing shows the card page.
    func testMyCardsAreEditableInDemoButNotSent() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        let title = app.textFields["cards-title"]
        app.revealInStudio(title)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText(" today")
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "today"), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [edited], timeout: 5), .completed, "Demo cards must stay editable")
        XCTAssertTrue(app.waitForLayoutPreview(caption: "Card page"), "Editing a card shows its page")
        XCTAssertFalse(app.buttons["profile-send"].isEnabled)
        XCTAssertTrue(app.staticTexts["Demo · cards are not saved"].exists)
        attach(app, "my-cards-demo")
    }

    /// A QR code made from a link becomes the card's image.
    func testQRCodeFromALinkBecomesTheCardImage() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        let menu = app.buttons["cards-image-menu"]
        app.revealInStudio(menu)
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let qr = app.buttons["QR code from text or link…"]
        XCTAssertTrue(qr.waitForExistence(timeout: 5))
        qr.tap()
        let input = app.descendants(matching: .any)["card-image-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("https://puritysb.github.io/pocket-daily/")
        let add = app.buttons["card-image-add"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: add)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 10), .completed, "The QR code was not generated")
        attach(app, "qr-code-sheet")
        add.tap()
        XCTAssertTrue(app.buttons["Replace image"].waitForExistence(timeout: 5)
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Replace image")).firstMatch.exists)
        XCTAssertTrue(app.waitForLayoutPreview(caption: "Card page"))
        attach(app, "qr-code-card")
    }

    /// Creating a `CBCentralManager` or probing the LAN is what raises the
    /// Bluetooth and local-network prompts, so both are deferred until the user
    /// asks to connect. A prompt on a cold launch is the regression this guards.
    func testLaunchRequestsNoPermissions() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["profile-canvas"].waitForExistence(timeout: 10))
        // Give a prompt time to appear if one were going to.
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3),
                       "A permission prompt appeared at launch: \(springboard.alerts.firstMatch.label)")
        app.open("Reader")
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try demo"].exists)
    }

    func testDirectConnectionRequiresConfirmationAndOfflinePreparationIsAvailable() {
        let app = XCUIApplication()
        app.launch()
        app.open("Reader")
        let choose = app.buttons["choose-file"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        XCTAssertTrue(choose.isEnabled)
        let help = app.buttons["How to connect"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        help.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Same Wi-Fi ·")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Direct ·")).firstMatch.exists)
        attach(app, "connection-guidance")
        let direct = app.buttons["Connect directly"]
        app.revealInReader(direct)
        direct.tap()
        XCTAssertTrue(app.staticTexts["Connect to the reader’s temporary Wi-Fi?"].waitForExistence(timeout: 5))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].isEnabled)
    }

    func testFilePickerStaysOpenWhileSearching() {
        let app = XCUIApplication()
        app.launch()
        app.open("Reader")
        let choose = app.buttons["choose-file"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        let search = app.searchFields.firstMatch
        // iPad collapses the system search field into a toolbar button.
        if !search.waitForExistence(timeout: 10) {
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
        app.open("Reader")
        let tryDemo = app.buttons["Try demo"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 10))
        tryDemo.tap()

        XCTAssertTrue(app.staticTexts["Demo · nothing is sent"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Exit demo"].exists)
        XCTAssertFalse(app.buttons["choose-file"].isEnabled, "Nothing may reach a device")
        // Reader settings are populated in Home & Sleep so they are reviewable...
        app.open("Home & Sleep")
        let startup = app.switches["profile-startup"]
        app.revealInStudio(startup)
        XCTAssertTrue(startup.exists)
        // ...but Send stays off.
        XCTAssertFalse(app.buttons["profile-send"].isEnabled)

        app.open("Reader")
        let exit = app.buttons["Exit demo"]
        app.revealInReader(exit, upward: true)
        exit.tap()
        XCTAssertTrue(app.buttons["Try demo"].waitForExistence(timeout: 5))
    }

    /// An empty discovery result must reach actionable UI, not an endless spinner.
    /// The DEBUG-only IO fixture runs the real retry/state logic without touching
    /// the user's LAN. Real subnet coverage/latency requires separate hardware tests.
    func testDiscoveryWithoutAReaderFailsQuicklyAndSaysWhatToDo() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-discovery"]
        app.launch()
        app.open("Reader")
        let find = app.buttons["Find on same Wi-Fi"]
        XCTAssertTrue(find.waitForExistence(timeout: 10))

        let started = Date()
        find.tap()

        let message = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", "No Pocket reader was visible")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "Discovery never reported a result")

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 10, "Empty discovery did not finish promptly")
    }

    /// The independent-project and privacy notices are a submission commitment,
    /// so they must be reachable from the shipping interface.
    func testAboutSheetStatesTheIndependenceAndPrivacyPosition() {
        let app = XCUIApplication()
        app.launch()
        app.open("Reader")
        let about = app.buttons["about-privacy"]
        app.revealInReader(about)
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()

        XCTAssertTrue(app.staticTexts["Independent project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Privacy"].exists)
        XCTAssertTrue(app.staticTexts["Firmware responsibility"].exists)
        XCTAssertTrue(app.buttons["Preview font notices"].exists)
    }
}
