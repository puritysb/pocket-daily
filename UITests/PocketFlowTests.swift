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

    func testContentEditorDemoIsEditableButCannotSaveOrApply() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let open = app.buttons["open-content-editor"]
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let addButton = app.buttons["content-add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        XCTAssertTrue(app.buttons["Choose image…"].waitForExistence(timeout: 5))
        let title = app.textFields["content-title-0"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Local card")
        let text = app.textViews["content-text-0"].exists ? app.textViews["content-text-0"] : app.textFields["content-text-0"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("One small step today.")
        // iPad's keyboard can hide the lazy Form's action section entirely.
        let hideKeyboard = app.buttons["Hide keyboard"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        let layout = app.descendants(matching: .any).matching(identifier: "content-layout-0").firstMatch
        for _ in 0..<4 where !layout.isHittable { app.swipeUp() }
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        layout.tap()
        let sideBySide = app.buttons["Side by side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 5))
        sideBySide.tap()
        let importContent = app.buttons["content-import"]
        for _ in 0..<4 where !importContent.exists { app.swipeUp() }
        XCTAssertTrue(importContent.waitForExistence(timeout: 5))
        XCTAssertFalse(importContent.isEnabled)
        XCTAssertFalse(app.buttons["content-export"].isEnabled)
        let preview = app.descendants(matching: .any).matching(identifier: "content-reader-preview").firstMatch
        for _ in 0..<6 {
            if preview.exists && preview.isHittable && preview.frame.maxY < app.frame.maxY - 80 { break }
            app.swipeUp()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.isHittable, "The rendered preview must be visible, not only present in accessibility.")
        let previewAttachment = XCTAttachment(screenshot: app.screenshot())
        previewAttachment.name = "content-reader-preview"
        previewAttachment.lifetime = .keepAlways
        add(previewAttachment)
        for _ in 0..<4 where !app.buttons["content-save"].exists || !app.buttons["content-apply"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["content-save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["content-apply"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["content-save"].isEnabled)
        XCTAssertFalse(app.buttons["content-apply"].isEnabled)
        XCTAssertTrue(app.buttons["content-live-apply"].exists)
        XCTAssertFalse(app.buttons["content-live-apply"].isEnabled)
        XCTAssertTrue(app.staticTexts["Unsaved local changes"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "content-editor-demo"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testContentImportReviewCancelConfirmAndExplicitSave() {
        let app = XCUIApplication()
        app.launchEnvironment["POCKET_UI_TEST_CONTENT_FILES_ID"] = UUID().uuidString
        app.launch()
        func openEditor() {
            let open = app.buttons["open-content-editor"]
            for _ in 0..<8 where !open.isHittable { app.swipeUp() }
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
            // A populated iPad form lazily creates the lower import section.
            // Either the first card or the empty draft's import action proves
            // loading finished; do not require an off-screen section to exist.
            let loaded = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier IN %@", ["content-title-0", "content-import"])).firstMatch
            XCTAssertTrue(loaded.waitForExistence(timeout: 5))
        }
        func importDraft() {
            let button = app.buttons["content-import"]
            for _ in 0..<6 where !button.isHittable { app.swipeUp() }
            button.tap()
            XCTAssertTrue(app.buttons["content-confirm-import"].waitForExistence(timeout: 5))
        }
        openEditor()
        importDraft()
        XCTAssertTrue(app.staticTexts["Imported cards"].exists)
        let review = XCTAttachment(screenshot: app.screenshot())
        review.name = "content-import-review"
        review.lifetime = .keepAlways
        add(review)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.textFields["content-title-0"].exists)
        importDraft()
        app.buttons["content-confirm-import"].tap()
        let title = app.textFields["content-title-0"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Imported card")
        app.terminate()
        app.launch()
        openEditor()
        XCTAssertFalse(app.textFields["content-title-0"].exists, "Import confirmation must not save")
        importDraft()
        app.buttons["content-confirm-import"].tap()
        let save = app.buttons["content-save"]
        for _ in 0..<8 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(app.buttons["content-apply"].isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["No unsaved local changes"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openEditor()
        XCTAssertEqual(app.textFields["content-title-0"].value as? String, "Imported card")
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
    }

    func testThemeMetricsCanBeEditedOfflineWithoutDeviceActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let editor = app.buttons["Edit theme metrics offline"]
        for _ in 0..<8 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let header = app.steppers["theme-header-height"]
        for _ in 0..<4 where !header.isHittable { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(header.isEnabled)
        // Query the actual button ID directly; scoped Stepper actions may
        // re-resolve as the generic "Increment" ID on compact layouts.
        let increment = app.buttons.matching(identifier: "theme-header-height-Increment").firstMatch
        for _ in 0..<3 where !increment.isHittable { app.swipeUp() }
        XCTAssertTrue(increment.waitForExistence(timeout: 5))
        increment.tap()
        XCTAssertEqual(header.value as? String, "45")
        let apply = app.buttons["theme-apply"]
        let revert = app.buttons["theme-revert"]
        let save = app.buttons["theme-save"]
        for _ in 0..<6 where !apply.exists || !revert.exists || !save.exists { app.swipeUp() }
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
        let recover = app.buttons["theme-recover"]
        for _ in 0..<8 where !recover.isHittable { app.swipeUp() }
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

        func openHeader() -> XCUIElement {
            let editor = app.buttons["Edit theme metrics offline"]
            for _ in 0..<8 where !editor.isHittable { app.swipeUp() }
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap()
            return app.steppers["theme-header-height"]
        }
        let header = openHeader()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let increment = app.buttons.matching(identifier: "theme-header-height-Increment").firstMatch
        for _ in 0..<4 where !increment.isHittable { app.swipeUp() }
        increment.tap()
        XCTAssertEqual(header.value as? String, "45")
        let save = app.buttons["theme-save"]
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["No unsaved theme changes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["theme-apply"].isEnabled)
        app.terminate()
        app.launch()
        let reopened = openHeader()
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, "45")
        XCTAssertFalse(app.buttons["theme-recover"].exists)
        let importButton = app.buttons["theme-import"]
        for _ in 0..<8 where !importButton.isHittable { app.swipeUp() }
        XCTAssertTrue(importButton.isEnabled)
        XCTAssertTrue(app.buttons["theme-export"].isEnabled)
        importButton.tap()
        let confirmImport = app.buttons["theme-confirm-import"]
        XCTAssertTrue(confirmImport.waitForExistence(timeout: 5))
        let review = XCTAttachment(screenshot: app.screenshot())
        review.name = "theme-import-review"
        review.lifetime = .keepAlways
        add(review)
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
        let unchanged = openHeader()
        XCTAssertEqual(unchanged.value as? String, "45")
        for _ in 0..<8 where !importButton.isHittable { app.swipeUp() }
        importButton.tap()
        XCTAssertTrue(confirmImport.waitForExistence(timeout: 5))
        confirmImport.tap()
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["No unsaved theme changes"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let imported = openHeader()
        XCTAssertEqual(imported.value as? String, "70")
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
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
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].exists)
        XCTAssertTrue(app.buttons["Explore without a reader"].exists)
    }

    func testDirectConnectionRequiresConfirmationAndOfflinePreparationIsAvailable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Choose file…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Choose file…"].isEnabled)
        let direct = app.buttons["Connect directly"]
        for _ in 0..<4 where !direct.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Same Wi-Fi ·")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "No router ·")).firstMatch.exists)
        let guidance = XCTAttachment(screenshot: app.screenshot())
        guidance.name = "connection-guidance"
        guidance.lifetime = .keepAlways
        add(guidance)
        direct.tap()
        XCTAssertTrue(app.staticTexts["Connect to the reader’s temporary Wi-Fi?"].waitForExistence(timeout: 5))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].isEnabled)
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

    /// An empty discovery result must reach actionable UI, not an endless spinner.
    /// The DEBUG-only IO fixture runs the real retry/state logic without touching
    /// the user's LAN. Real subnet coverage/latency requires separate hardware tests.
    func testDiscoveryWithoutAReaderFailsQuicklyAndSaysWhatToDo() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-discovery"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Reader profile"].waitForExistence(timeout: 10))

        let started = Date()
        app.buttons["Find on same Wi-Fi"].tap()

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
        XCTAssertTrue(app.staticTexts["Reader profile"].waitForExistence(timeout: 10))

        (app.buttons["About"].exists ? app.buttons["About"] : app.buttons["About & Privacy"]).tap()

        XCTAssertTrue(app.staticTexts["Independent project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Privacy"].exists)
        XCTAssertTrue(app.staticTexts["Firmware responsibility"].exists)
    }
}
