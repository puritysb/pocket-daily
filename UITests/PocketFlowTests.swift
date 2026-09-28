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

    /// Home opens first and redraws the firmware layout for each edit; Sleep is
    /// its own screen with its own controls; demo never enables Apply.
    func testHomeAndSleepEditorPreviewsEditsInDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--hardware=X3"]
        app.launch()
        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        // The daily panel contains weather and the next event as sibling settings.
        let weather = app.switches["profile-home-weather"]
        app.revealInStudio(weather)
        weather.tap()
        XCTAssertTrue(app.waitForLayoutPreview(), "The weather edit was not redrawn")
        XCTAssertFalse(app.switches["profile-next-event"].exists, "Daily panel settings fold away with it")
        XCTAssertFalse(app.buttons["profile-apply"].isEnabled)
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled)

        XCTAssertFalse(app.buttons["Reader's sleep screen"].exists, "Sleep controls belong to the Sleep screen")
        app.openScreen("Sleep")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Daily Brief never rendered")
        let readerSleep = app.buttons["Reader's sleep screen"]
        app.revealInStudio(readerSleep)
        readerSleep.tap()
        // The reader's own sleep screen is an outline.
        XCTAssertTrue(app.waitForLayoutPreview(caption: "Layout outline"))
        XCTAssertTrue(app.buttons["Sleep"].isSelected)
        let brief = app.buttons["Daily Brief"]
        brief.tap()
        XCTAssertTrue(app.waitForLayoutPreview(), "The Daily Brief was not drawn")
        attach(app, "home-sleep-editor")

        app.buttons["profile-revert"].tap()
        app.buttons["Discard edits"].tap()
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
    }

    func testScreensSeparateWeatherAndCalendarWithoutRequestingAccessInDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.open("Screens")
        let event = app.switches["profile-next-event"]
        app.revealInStudio(event)
        XCTAssertTrue(event.isHittable)
        XCTAssertTrue(app.staticTexts["Calendar"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["weather-data-sources"].exists)
        XCTAssertFalse(app.buttons["glance-events"].exists, "Demo must not offer private Calendar access")
        attach(app, "daily-panel-sources")
        event.tap()
        XCTAssertTrue(app.waitForLayoutPreview())
        XCTAssertTrue(app.descendants(matching: .any)["weather-data-sources"].exists, "Calendar visibility must not remove Weather attribution")
        app.openScreen("Sleep")
        let weather = app.switches["profile-sleep-weather"]
        app.revealInStudio(weather)
        weather.tap()
        let calendar = app.switches["profile-sleep-today"]
        app.revealInStudio(calendar)
        XCTAssertTrue(calendar.exists, "Sleep Calendar remains independently selectable")
        XCTAssertFalse(app.descendants(matching: .any)["weather-data-sources"].exists)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        attach(app, "separate-weather-calendar")
    }

    func testReadingSettingsAreEditableOfflineAndDiscardIsExplicit() {
        let app = XCUIApplication()
        app.launch()
        app.open("Screens")
        let size = app.buttons["Extra large"]
        app.revealInStudio(size)
        XCTAssertTrue(size.isHittable)
        size.tap()
        XCTAssertFalse(app.buttons["profile-side-buttons-1"].exists)
        app.revealCanvas()
        XCTAssertTrue(app.staticTexts["Text size example · approximate appearance"].exists)
        XCTAssertFalse(app.buttons["profile-apply"].isEnabled)
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled)
        attach(app, "offline-reading-settings")
        app.buttons["profile-revert"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(size.isSelected)
        app.buttons["profile-revert"].tap()
        app.buttons["Discard edits"].tap()
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled)
    }

    /// My cards open under their Home page; editing shows the card page.
    func testMyCardsAreEditableInDemoButNotSent() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        app.openCards()
        let title = app.textFields["cards-title"]
        app.revealInStudio(title)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText(" today")
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "today"), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [edited], timeout: 5), .completed, "Demo cards must stay editable")
        let canvas = app.descendants(matching: .any)["profile-canvas"]
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "today"), object: canvas)
        XCTAssertEqual(XCTWaiter().wait(for: [updated], timeout: 5), .completed, "The canvas must observe each card edit")
        XCTAssertTrue(app.waitForLayoutPreview(caption: "Card page"), "Editing a card shows its page")
        XCTAssertTrue(canvas.isHittable, "Keep the preview visible above the keyboard")
        XCTAssertFalse(app.buttons["profile-apply"].isEnabled)
        XCTAssertTrue(app.staticTexts["Demo · cards are not saved"].exists)
        attach(app, "my-cards-demo")
    }

    /// A QR code made from a link becomes the card's image.
    func testQRCodeFromALinkBecomesTheCardImage() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview(), "The Home preview never rendered")
        app.openCards()
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

        // The Library opens first and needs no permission at all.
        XCTAssertTrue(app.buttons["library-add"].waitForExistence(timeout: 10))
        // Give a prompt time to appear if one were going to.
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3),
                       "A permission prompt appeared at launch: \(springboard.alerts.firstMatch.label)")
        app.open("Device")
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try demo"].exists)
    }

    func testDirectConnectionRequiresConfirmationAndOfflinePreparationIsAvailable() {
        let app = XCUIApplication()
        app.launch()
        app.open("Device")
        let add = app.buttons["files-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isEnabled, "Files can be prepared before a reader is connected")
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
        app.open("Device")
        let add = app.buttons["files-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let choose = app.buttons["choose-file"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
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

    /// EPUB creation is local, keeps text after validation failure, and queues a durable copy.
    func testTypedTextCanBecomeAnOfflineEPUB() {
        let app = XCUIApplication()
        app.launch()
        app.open("Device")
        let add = app.buttons["files-add"]
        app.revealInReader(add)
        add.tap()
        app.buttons["write-text"].tap()
        let title = app.textFields["compose-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["EPUB"].isSelected)
        let prepare = app.buttons["compose-prepare"]
        XCTAssertFalse(prepare.isEnabled)
        title.tap()
        title.typeText(String(repeating: "x", count: 257))
        let text = app.textViews["compose-text"]
        text.tap()
        text.typeText("An offline reading document.\n\nSecond paragraph.")
        prepare.tap()
        XCTAssertTrue(app.staticTexts["compose-error"].waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String)?.contains("Second paragraph") == true)
        app.buttons["compose-cancel"].tap()
        add.tap()
        app.buttons["write-text"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Offline EPUB check")
        text.tap()
        text.typeText("An offline reading document.\n\nSecond paragraph.")
        prepare.tap()
        let filename = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@",
                                                            "Offline EPUB check-", ".epub")).firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 10))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.terminate()
        app.launch()
        app.open("Device")
        XCTAssertTrue(filename.waitForExistence(timeout: 10), "Prepared EPUB must survive relaunch")
        let remove = app.buttons["Remove content…"]
        app.revealInReader(remove)
        XCTAssertTrue(app.buttons["Send content"].exists)
        XCTAssertFalse(app.buttons["Send firmware"].exists, "Written text must not become a firmware transfer")
        XCTAssertFalse(app.buttons["Choose firmware file…"].exists)
        XCTAssertFalse(app.buttons["Remove firmware…"].exists)
        attach(app, "content-transfer-queue")
        remove.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(filename.exists, "Cancelling removal must preserve the prepared content")
        remove.tap()
        app.buttons["Remove prepared copies"].tap()
    }

    func testSystemShareExtensionSavesTextIntoAppLibrary() {
        let app = XCUIApplication()
        let articleTitle = "Shared article " + UUID().uuidString.prefix(8)
        app.launchArguments = ["--ui-test-article-share"]
        app.launch()
        app.buttons["Share selected article text"].tap()
        let destination = app.cells["Pocket Daily"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.tap()
        let title = app.textFields["article-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText(articleTitle)
        XCTAssertTrue((app.textViews["article-body"].value as? String)?.contains("Selected article text") == true)
        attach(app, "article-share-capture")
        app.buttons["article-save"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed)
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.openShelf("Articles")
        XCTAssertTrue(app.staticTexts[articleTitle].waitForExistence(timeout: 10))
        attach(app, "article-library-shared")
        app.buttons["article-options-" + articleTitle].tap()
        app.buttons["Delete"].firstMatch.tap()
        let delete = app.buttons["Delete " + articleTitle]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
    }

    /// Articles live in the Library: saved offline, read on this device, and
    /// prepared as the same EPUB for the reader.
    func testArticleCanBeSavedReadAndPrepared() {
        let articleTitle = "Article check " + UUID().uuidString.prefix(8)
        let app = XCUIApplication()
        app.launch()
        app.openShelf("Articles")
        app.buttons["article-add-menu"].tap()
        app.buttons["article-add"].tap()
        let title = app.textFields["article-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(articleTitle)
        let body = app.textViews["article-body"]
        body.tap()
        body.typeText("A saved article for reading offline. Second sentence.")
        app.buttons["article-save"].tap()
        let saved = app.staticTexts[articleTitle].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))

        app.buttons["Read " + articleTitle].tap()
        XCTAssertTrue(app.staticTexts["reader-progress"].waitForExistence(timeout: 20), "The article never opened")
        XCTAssertTrue(app.webViews.staticTexts[articleTitle].waitForExistence(timeout: 20), "The article text never rendered")
        attach(app, "article-reading")
        app.descendants(matching: .any)["reader-page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader-close"].waitForExistence(timeout: 5))
        app.buttons["reader-close"].tap()
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["reader-progress"])
        XCTAssertEqual(XCTWaiter().wait(for: [returned], timeout: 10), .completed)

        app.filterArticles("All articles")
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        app.buttons["article-options-" + articleTitle].tap()
        app.buttons["Prepare for reader"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Ready in Device")).firstMatch.waitForExistence(timeout: 10))
        attach(app, "article-library-prepared")
        app.open("Device")
        let filename = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "pd-article-", ".epub")).firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        app.openShelf("Articles")
        app.filterArticles("All articles")
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        app.buttons["article-options-" + articleTitle].tap()
        app.buttons["Delete"].firstMatch.tap()
        let confirmDelete = app.buttons["Delete " + articleTitle]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: saved)
        XCTAssertEqual(XCTWaiter().wait(for: [removed], timeout: 5), .completed)
        app.open("Device")
        let remove = app.buttons["Remove content…"]
        app.revealInReader(remove)
        remove.tap()
        app.buttons["Remove prepared copies"].tap()
    }

    /// Demo mode is the path App Review uses without hardware. It must populate
    /// the interface while leaving every device-mutating control disabled.
    func testDemoModeIsPopulatedButCannotTransfer() {
        let app = XCUIApplication()
        app.launch()
        app.open("Device")
        let tryDemo = app.buttons["Try demo"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 10))
        tryDemo.tap()

        XCTAssertTrue(app.staticTexts["Demo · nothing is sent"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Exit demo"].exists)
        XCTAssertFalse(app.buttons["files-add"].isEnabled, "Nothing may reach a device")
        // Reader settings are populated in Home & Sleep so they are reviewable...
        app.open("Screens")
        let startup = app.switches["profile-startup"]
        app.revealInStudio(startup)
        XCTAssertTrue(startup.exists)
        // ...but Apply stays off.
        XCTAssertFalse(app.buttons["profile-apply"].isEnabled)

        app.open("Device")
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
        app.open("Device")
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

    func testConnectionSearchCanBeCancelledAndRetried() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-slow-discovery"]
        app.launch()
        app.open("Device")
        let find = app.buttons["Find on same Wi-Fi"]
        find.tap()
        let cancel = app.buttons["cancel-reader-connection"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let message = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Connection cancelled")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(find.isEnabled)
        find.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
    }

    func testEmptyArticlesAreCenteredInAvailableSpace() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-feeds=empty-layout-\(UUID().uuidString)", "--ui-test-fresh-library"]
        app.launch()
        app.openShelf("Articles")
        let empty = app.descendants(matching: .any)["article-empty-state"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        let title = app.staticTexts["Room for a good read"]
        XCTAssertTrue(title.isHittable)
        XCTAssertEqual(title.frame.midX, empty.frame.midX, accuracy: 5)
        XCTAssertEqual(title.frame.midY, empty.frame.midY, accuracy: 80)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "qa-centered-articles"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testStudioKeepsPreviewVisibleWhileEditing() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.open("Screens")
        let canvas = app.descendants(matching: .any)["profile-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let before = canvas.frame
        app.scrollViews["profile-controls"].swipeUp()
        XCTAssertTrue(canvas.isHittable)
        XCTAssertEqual(canvas.frame.minY, before.minY, accuracy: 2)
        XCTAssertTrue(app.buttons["profile-apply"].isHittable)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "qa-persistent-preview"
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// The independent-project and privacy notices are a submission commitment,
    /// so they must be reachable from the shipping interface.
    func testAboutSheetStatesTheIndependenceAndPrivacyPosition() {
        let app = XCUIApplication()
        app.launch()
        app.open("Device")
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
