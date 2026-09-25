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

    func testCardStudioDemoIsEditableButCannotSend() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.open("Cards")
        let title = app.textFields["studio-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let canvas = app.descendants(matching: .any)["studio-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Reader preview of the selected card"), object: canvas)
        XCTAssertEqual(XCTWaiter().wait(for: [rendered], timeout: 15), .completed, "The card preview never rendered")
        title.tap()
        title.typeText(" today")
        // Where the caret lands depends on the field width; the edit must stick.
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "today"), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [edited], timeout: 5), .completed, "Demo cards must stay editable: \(title.value ?? "")")
        XCTAssertFalse(app.buttons["studio-send"].isEnabled)
        XCTAssertFalse(app.switches["studio-auto-send"].isEnabled)
        app.swipeDown()
        let importCards = app.buttons["studio-import"]
        app.revealInStudio(importCards)
        XCTAssertTrue(importCards.exists)
        XCTAssertFalse(importCards.isEnabled)
        XCTAssertFalse(app.buttons["studio-export"].isEnabled)
        XCTAssertTrue(app.staticTexts["Demo · edits are not saved"].exists)
        attach(app, "card-studio-demo")
    }

    /// Import is reviewed before it replaces the draft; the confirmed draft is
    /// then saved locally and survives a relaunch without being sent.
    func testCardImportReviewCancelConfirmAndLocalSave() {
        let app = XCUIApplication()
        app.launchEnvironment["POCKET_UI_TEST_CONTENT_FILES_ID"] = UUID().uuidString
        app.launch()
        func openCards() {
            app.open("Cards")
            let loaded = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier IN %@", ["studio-title", "studio-import"])).firstMatch
            XCTAssertTrue(loaded.waitForExistence(timeout: 10))
        }
        func importDraft() {
            let button = app.buttons["studio-import"]
            app.revealInStudio(button)
            button.tap()
            XCTAssertTrue(app.buttons["content-confirm-import"].waitForExistence(timeout: 5))
        }
        openCards()
        XCTAssertFalse(app.textFields["studio-title"].exists)
        importDraft()
        XCTAssertTrue(app.staticTexts["Imported cards"].exists)
        attach(app, "content-import-review")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.textFields["studio-title"].exists, "Cancel must keep the draft")
        importDraft()
        app.buttons["content-confirm-import"].tap()
        let title = app.textFields["studio-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Imported card")
        XCTAssertFalse(app.buttons["studio-send"].isEnabled, "Nothing is sent without a reader")
        let saved = app.staticTexts["Saved on this device"]
        app.revealInStudio(saved)
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        openCards()
        XCTAssertEqual(app.textFields["studio-title"].value as? String, "Imported card")
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
    }

    /// Theme metrics live under Reader → Advanced.
    private func openThemeEditor(_ app: XCUIApplication) -> XCUIElement {
        app.open("Reader")
        let advanced = app.buttons["Advanced"]
        app.revealInReader(advanced)
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        let editor = app.buttons["Edit theme metrics offline"]
        app.revealInReader(editor)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        return app.steppers["theme-header-height"]
    }

    func testThemeMetricsCanBeEditedOfflineWithoutDeviceActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let header = openThemeEditor(app)
        app.revealInReader(header)
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(header.isEnabled)
        // Query the actual button ID directly; scoped Stepper actions may
        // re-resolve as the generic "Increment" ID on compact layouts.
        let increment = app.buttons.matching(identifier: "theme-header-height-Increment").firstMatch
        app.revealInReader(increment)
        XCTAssertTrue(increment.waitForExistence(timeout: 5))
        increment.tap()
        XCTAssertEqual(header.value as? String, "45")
        let apply = app.buttons["theme-apply"]
        let revert = app.buttons["theme-revert"]
        let save = app.buttons["theme-save"]
        app.revealInReader(apply)
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(revert.waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
        XCTAssertFalse(revert.isEnabled)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.buttons["theme-import"].exists)
        XCTAssertTrue(app.buttons["theme-export"].exists)
        XCTAssertFalse(app.buttons["theme-import"].isEnabled)
        XCTAssertFalse(app.buttons["theme-export"].isEnabled)
        XCTAssertFalse(app.buttons["theme-recover"].exists)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
    }

    func testThemeRecoveryRequiresConfirmationAndSavedEditsSurviveRelaunch() {
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        app.launchEnvironment["POCKET_UI_TEST_THEME_DRAFT_ID"] = fixtureID
        app.launchEnvironment["POCKET_UI_TEST_THEME_IMPORT_ID"] = fixtureID
        app.launch()
        app.open("Reader")
        let advanced = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Advanced")).firstMatch
        app.revealInReader(advanced)
        advanced.tap()
        let recover = app.buttons["theme-recover"]
        app.revealInReader(recover)
        XCTAssertTrue(recover.waitForExistence(timeout: 5))
        recover.tap()
        XCTAssertTrue(app.buttons["Preserve file and recover theme"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(recover.exists)
        XCTAssertFalse(app.buttons["Export preserved theme draft"].exists)
        recover.tap()
        app.buttons["Preserve file and recover theme"].tap()
        XCTAssertTrue(app.buttons["Export preserved theme draft"].waitForExistence(timeout: 5))
        XCTAssertFalse(recover.exists)

        let editor = app.buttons["Edit theme metrics offline"]
        app.revealInReader(editor)
        editor.tap()
        let header = app.steppers["theme-header-height"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let increment = app.buttons.matching(identifier: "theme-header-height-Increment").firstMatch
        app.revealInReader(increment)
        increment.tap()
        XCTAssertEqual(header.value as? String, "45")
        let save = app.buttons["theme-save"]
        app.revealInReader(save)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["No unsaved theme changes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["theme-apply"].isEnabled)
        app.terminate()
        app.launch()
        let reopened = openThemeEditor(app)
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, "45")
        XCTAssertFalse(app.buttons["theme-recover"].exists)
        let importButton = app.buttons["theme-import"]
        app.revealInReader(importButton)
        XCTAssertTrue(importButton.isEnabled)
        XCTAssertTrue(app.buttons["theme-export"].isEnabled)
        importButton.tap()
        let confirmImport = app.buttons["theme-confirm-import"]
        XCTAssertTrue(confirmImport.waitForExistence(timeout: 5))
        attach(app, "theme-import-review")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(reopened.value as? String, "45")
        importButton.tap()
        XCTAssertTrue(confirmImport.waitForExistence(timeout: 5))
        confirmImport.tap()
        XCTAssertTrue(app.staticTexts["Unsaved theme changes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["theme-apply"].isEnabled)
        // Import confirmation changes memory only; relaunch before Save must
        // retain the last saved value, not silently persist imported values.
        app.terminate()
        app.launch()
        let unchanged = openThemeEditor(app)
        XCTAssertEqual(unchanged.value as? String, "45")
        app.revealInReader(importButton)
        importButton.tap()
        XCTAssertTrue(confirmImport.waitForExistence(timeout: 5))
        confirmImport.tap()
        app.revealInReader(save)
        save.tap()
        XCTAssertTrue(app.staticTexts["No unsaved theme changes"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let imported = openThemeEditor(app)
        XCTAssertEqual(imported.value as? String, "70")
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
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
        // Settings are populated so the interface is reviewable...
        let startup = app.switches["Start on Pocket Daily"]
        app.revealInReader(startup)
        XCTAssertTrue(startup.exists)
        // ...but nothing may reach a device.
        XCTAssertFalse(app.buttons["choose-file"].isEnabled)
        XCTAssertFalse(app.buttons["Demo · not saved"].isEnabled)

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
