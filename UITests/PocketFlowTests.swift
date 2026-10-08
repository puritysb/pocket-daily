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
        XCTAssertTrue(app.segmentedControls["profile-screen"].exists)
        let brief = app.buttons["Daily Brief"]
        brief.tap()
        XCTAssertTrue(app.waitForLayoutPreview(), "The Daily Brief was not drawn")
        attach(app, "home-sleep-editor")
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled, "Home edits must not dirty Sleep")
        app.openScreen("Home")
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled)
        app.buttons["profile-revert"].tap()
        app.buttons["Discard edits"].tap()
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
    }

    func testSleepWakeIndicatorCanBePreviewedAndDiscarded() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--hardware=X3"]
        app.launch()
        app.open("Screens")
        app.openScreen("Sleep")
        XCTAssertTrue(app.waitForLayoutPreview())
        let wake = app.switches["profile-sleep-wake"]
        app.revealInStudio(wake)
        XCTAssertEqual(wake.value as? String, "1")
        wake.tap()
        XCTAssertEqual(wake.value as? String, "0")
        XCTAssertTrue(app.waitForLayoutPreview())
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled)
        XCTAssertFalse(app.buttons["profile-apply"].isEnabled)
        attach(app, "qa-wake-off")
        app.buttons["profile-revert"].tap()
        app.buttons["Discard edits"].tap()
        app.revealInStudio(wake)
        XCTAssertEqual(wake.value as? String, "1")
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled)
        attach(app, "qa-wake-on")
    }

    func testScreensShareWeatherAndCalendarEditorWithoutChangingParentTarget() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview())
        let canvas = app.descendants(matching: .any)["profile-canvas"]
        let home = canvas.label
        app.openWeatherAndCalendar()
        XCTAssertTrue(app.staticTexts["Weather"].exists)
        XCTAssertTrue(app.staticTexts["Calendar"].exists)
        XCTAssertTrue(app.staticTexts["Example events · your calendars are not accessed"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["weather-data-sources"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "content-editor-apply").count, 1)
        XCTAssertFalse(app.buttons["profile-apply"].isHittable, "The parent must not offer a competing Apply inside the source task")
        XCTAssertFalse(app.buttons["glance-events"].exists)
        attach(app, "qa-home-shared-content")
        app.buttons["content-editor-close"].tap()
        XCTAssertTrue(app.segmentedControls["profile-screen"].buttons["Home"].isSelected)
        XCTAssertEqual(canvas.label, home)
        app.openScreen("Sleep")
        XCTAssertTrue(app.waitForLayoutPreview())
        let sleep = canvas.label
        app.openWeatherAndCalendar()
        XCTAssertTrue(app.staticTexts["Weather & calendar"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["weather-data-sources"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "content-editor-apply").count, 1)
        app.buttons["content-editor-close"].tap()
        XCTAssertTrue(app.segmentedControls["profile-screen"].buttons["Sleep"].isSelected)
        XCTAssertEqual(canvas.label, sleep)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
    }

    func testSourceConnectionStaysInsideEditorAndPreservesParent() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-discovery"]
        app.launch()
        app.open("Screens")
        app.openScreen("Sleep")
        let canvas = app.descendants(matching: .any)["profile-canvas"]
        let sleep = canvas.label
        app.openWeatherAndCalendar()
        let city = app.textFields["glance-city-field"]
        if !city.exists { app.buttons["Change"].firstMatch.tap() }
        XCTAssertTrue(city.waitForExistence(timeout: 5))
        city.tap()
        city.typeText("typed city draft")
        let query = city.value as? String
        let connect = app.buttons["content-editor-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect directly"].exists)
        XCTAssertFalse(app.buttons["try-demo"].exists, "Demo must not abandon an editor's pending work")
        XCTAssertFalse(city.exists, "Hidden editor inputs must not remain accessible during connection")
        app.buttons["content-connection-back"].tap()
        XCTAssertTrue(app.staticTexts["Weather & calendar"].waitForExistence(timeout: 5))
        XCTAssertEqual(city.value as? String, query, "Connect and Back must preserve the unsubmitted city query")
        app.buttons["content-editor-close"].tap()
        XCTAssertTrue(app.segmentedControls["profile-screen"].buttons["Sleep"].isSelected)
        XCTAssertEqual(canvas.label, sleep)
        app.open("Reading")
        XCTAssertFalse(app.descendants(matching: .any)["content-editor-sheet"].exists, "A consumed source request must not reopen on Reading")
    }

    func testReadingSettingsAreEditableOfflineAndDiscardIsExplicit() {
        let app = XCUIApplication()
        app.launch()
        app.open("Screens")
        app.openScreen("Reading")
        if app.buttons["profile-revert"].isEnabled {
            app.buttons["profile-revert"].tap()
            app.buttons["Discard edits"].tap()
        }
        app.openScreen("Home")
        // Offline drafts persist across launches. Establish the loaded baseline
        // before asserting that another area's edits survive the connection sheet.
        if app.buttons["profile-revert"].isEnabled {
            app.buttons["profile-revert"].tap()
            app.buttons["Discard edits"].tap()
        }
        let homeWeather = app.switches["profile-home-weather"]
        app.revealInStudio(homeWeather)
        homeWeather.tap()
        app.openScreen("Reading")
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled, "Reading starts clean despite Home edits")
        let size = app.buttons["profile-text-size"]
        app.revealInStudio(size)
        app.chooseMenu("profile-text-size", option: "Extra large")
        XCTAssertFalse(app.buttons["profile-preview-reading"].exists)
        XCTAssertFalse(app.buttons["profile-back-to-layout"].exists)
        app.revealCanvas()
        XCTAssertTrue(app.staticTexts["Reading preview · approximate appearance"].exists)
        XCTAssertTrue(app.buttons["profile-connect"].isEnabled)
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled)
        attach(app, "offline-reading-settings")
        let landscape = app.buttons["Landscape"]
        app.revealInStudio(landscape)
        landscape.tap()
        app.revealCanvas()
        XCTAssertTrue(app.descendants(matching: .any)["profile-canvas"].label.contains("Landscape"))
        attach(app, "offline-reading-landscape")
        app.buttons["profile-connect"].tap()
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect directly"].exists)
        app.openOtherConnectionMethods()
        XCTAssertTrue(app.buttons["Connect directly"].exists)
        attach(app, "connect-from-reading")
        app.buttons["connection-done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["profile-canvas"].label.contains("Landscape"))
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled)
        app.openScreen("Home")
        app.openScreen("Reading")
        XCTAssertTrue(app.descendants(matching: .any)["profile-canvas"].label.contains("Landscape"))
        app.buttons["profile-revert"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["profile-canvas"].label.contains("text size 4 of 4"))
        app.buttons["profile-revert"].tap()
        app.buttons["Discard edits"].tap()
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled)
        app.openScreen("Home")
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled, "Discarding Reading must preserve Home edits")
    }

    func testSelectedBookTaskPreservesLibraryAndReopensAfterConnection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fresh-library"]
        app.launch()
        let search = app.textFields["library-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Welcome")
        let book = app.buttons["book-Welcome to Pocket Daily"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.press(forDuration: 1)
        app.buttons["send-book-to-reader"].tap()
        let connect = app.buttons["book-transfer-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["book-transfer-send"].exists)
        connect.tap()
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["try-demo"].exists, "Demo must not be offered inside a book transfer")
        app.buttons["book-transfer-connection-back"].tap()
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        app.buttons["book-transfer-close"].tap()
        XCTAssertEqual(search.value as? String, "Welcome")
        app.buttons["book-transfer-reopen"].tap()
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        attach(app, "selected-book-task")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "Preparing must not request network access")
    }

    func testReaderOverviewExposesFourDestinationsOffline() {
        let app = XCUIApplication()
        app.launch()
        app.open("My Reader")
        for destination in ["On Reader", "Screens", "Reading", "Device"] {
            if app.isCompact { XCTAssertTrue(app.buttons["reader-destination-\(destination)"].waitForExistence(timeout: 5)) }
            else {
                XCTAssertTrue(app.buttons["navigation-\(destination)"].exists)
                XCTAssertFalse(app.buttons["reader-destination-\(destination)"].exists, "Overview must not repeat its sidebar")
            }
        }
        attach(app, "qa-reader-overview-offline")
        app.open("Reading")
        XCTAssertFalse(app.buttons["Screen design"].exists)
        XCTAssertFalse(app.buttons["device-pages"].exists)
    }

    func testScreensAndReadingNavigationPreservesDistinctScopes() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--hardware=X3"]
        app.launch()
        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview())
        let weather = app.switches["profile-home-weather"]
        app.revealInStudio(weather)
        weather.tap()
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled)
        app.open("Reading")
        XCTAssertTrue(app.staticTexts["Reading preview · approximate appearance"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["profile-screen"].exists)
        XCTAssertFalse(app.buttons["profile-revert"].isEnabled, "Home changes must not appear as Reading changes")
        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview())
        XCTAssertTrue(app.segmentedControls["profile-screen"].exists)
        XCTAssertTrue(app.buttons["profile-revert"].isEnabled, "The same editor keeps Home changes across destination navigation")
        attach(app, "qa-editor-destination-scopes")
    }

    func testReadingButtonsPreviewBothReaderModelsAndOrientations() {
        for hardware in ["X3", "X4"] {
            let app = XCUIApplication()
            app.launchArguments = ["--demo", "--hardware=\(hardware)"]
            app.launch()
            app.open("Reading")
            let canvas = app.descendants(matching: .any)["profile-canvas"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 15))
            let diagram = app.descendants(matching: .any)["reader-button-diagram"]
            app.revealInStudio(diagram)
            XCTAssertTrue(diagram.waitForExistence(timeout: 5))
            alignReadingDiagramForCapture(diagram, in: app)
            attach(app, "qa-buttons-\(hardware)-portrait")
            let landscape = app.buttons["Landscape"]
            app.revealInStudio(landscape)
            landscape.tap()
            app.revealInStudio(diagram)
            alignReadingDiagramForCapture(diagram, in: app)
            attach(app, "qa-buttons-\(hardware)-landscape")
            XCTAssertFalse(app.buttons["profile-apply"].isEnabled)
            app.terminate()
        }
    }

    private func alignReadingDiagramForCapture(_ diagram: XCUIElement, in app: XCUIApplication) {
        let controls = app.scrollViews["profile-controls"]
        for _ in 0..<6 {
            let visible = controls.frame.intersection(app.frame)
            let top = visible.minY + 6
            let bottom = min(visible.maxY, app.buttons["profile-apply"].frame.minY) - 6
            if diagram.frame.minY >= top && diagram.frame.maxY <= bottom { return }
            let movement = max(-80, min(80, (top + bottom) / 2 - diagram.frame.midY))
            guard abs(movement) > 2 else { return }
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: visible.minX + 12, dy: (top + bottom) / 2))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: movement)))
        }
    }

    func testMyCardsEditorPreservesHomeTargetAndHasOneApply() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview())
        let parent = app.descendants(matching: .any)["profile-canvas"]
        let label = parent.label
        app.openCards()
        let title = app.textFields["cards-title"]
        app.revealInStudio(title)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText(" today")
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "today"), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [edited], timeout: 5), .completed)
        let canvas = app.descendants(matching: .any)["card-editor-canvas"]
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "today"), object: canvas)], timeout: 5), .completed)
        XCTAssertTrue(app.waitForCardPreview())
        XCTAssertEqual(app.buttons.matching(identifier: "content-editor-apply").count, 1)
        XCTAssertFalse(app.buttons["content-editor-apply"].isEnabled)
        XCTAssertFalse(app.buttons["profile-apply"].isHittable)
        app.revealCanvas()
        attach(app, "qa-dedicated-card-editor")
        app.buttons["content-editor-close"].tap()
        XCTAssertTrue(app.segmentedControls["profile-screen"].buttons["Home"].isSelected)
        XCTAssertEqual(parent.label, label, "Card edits must not turn the parent into Card page")
        app.open("Reading")
        XCTAssertFalse(app.descendants(matching: .any)["content-editor-sheet"].exists)
    }

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
        XCTAssertTrue(app.waitForCardPreview())
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

    func testAppearanceSelectionUpdatesAndSurvivesReopeningSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-discovery"]
        app.launch()
        app.openSettings()
        let modes = ["system", "light", "dark"]
        let original = modes.first { app.buttons["app-appearance-" + $0].isSelected } ?? "system"
        for mode in ["dark", "light", "system", "dark"] {
            let button = app.buttons["app-appearance-" + mode]
            button.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 2), .completed)
            XCTAssertEqual(modes.filter { app.buttons["app-appearance-" + $0].isSelected }, [mode])
        }
        attach(app, "qa-settings-dark")
        app.buttons["Done"].tap()
        app.openSettings()
        XCTAssertTrue(app.buttons["app-appearance-dark"].isSelected)
        app.buttons["app-appearance-" + original].tap()
        app.buttons["Done"].tap()
    }

    func testBluetoothSetupIsExplicitAndHiddenInDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-discovery"]
        app.launch()
        app.openSettings()
        let enabled = app.switches["sync-reader-exchange"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String == "0" { enabled.tap() }
        XCTAssertFalse(app.staticTexts["sync-bluetooth-hint"].exists, "Connection instructions stay folded until requested")
        XCTAssertFalse(app.buttons["sync-bluetooth-setup"].exists, "Pairing belongs on Device, not in Settings")
        attach(app, "qa-settings-compact")
        let guide = app.buttons["settings-guide"]
        if !guide.isHittable { app.swipeUp() }
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        guide.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
            "Each device needs the same book file.")).firstMatch.waitForExistence(timeout: 5))
        attach(app, "qa-settings-guide")
        app.buttons["Done"].tap()
        // Pairing sits on Device, with the other ways of reaching the reader.
        app.open("Device")
        XCTAssertTrue(app.buttons["sync-bluetooth-setup"].waitForExistence(timeout: 5))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        attach(app, "ble-reading-sync-setup")
        app.terminate()
        app.launchArguments = ["--demo"]
        app.launch()
        app.openSettings()
        XCTAssertTrue(app.switches["sync-reader-exchange"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["sync-bluetooth-hint"].exists)
        app.buttons["Done"].tap()
        app.open("Device")
        XCTAssertTrue(app.buttons["try-demo"].exists || app.buttons["Exit demo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sync-bluetooth-setup"].exists)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        attach(app, "ble-reading-sync-demo")
    }

    func testDirectConnectionRequiresConfirmationAndOfflinePreparationIsAvailable() {
        let app = XCUIApplication()
        app.launch()
        app.open("On Reader")
        app.openReaderOnlyFiles()
        let add = app.buttons["reader-only-files-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isEnabled, "Files can be prepared before a reader is connected")
        app.open("Device")
        XCTAssertTrue(app.staticTexts["On the reader: Pocket Daily → Sync → Same Wi-Fi."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect directly"].exists)
        app.openOtherConnectionMethods()
        XCTAssertTrue(app.staticTexts["On the reader: Pocket Daily → Sync → Direct connection."].exists)
        attach(app, "connection-guidance")
        let direct = app.buttons["Connect directly"]
        app.revealInReader(direct)
        direct.tap()
        XCTAssertTrue(app.staticTexts["Connect to the reader’s temporary Wi-Fi?"].waitForExistence(timeout: 5))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Find on same Wi-Fi"].isEnabled)
    }

    func testOnReaderOwnsInventoryAndLibraryOwnsContentCreation() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.open("On Reader")
        XCTAssertTrue(app.buttons["inventory-choose-library"].exists)
        XCTAssertFalse(app.buttons["Write text to read…"].exists)
        XCTAssertFalse(app.buttons["prepare-symbol-font"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["reader-memory-diagnostic"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Previous")).firstMatch.exists)
        app.openReaderOnlyFiles()
        XCTAssertFalse(app.buttons["reader-only-files-add"].isEnabled)
        app.buttons["inventory-choose-library"].tap()
        app.buttons["library-add"].tap()
        XCTAssertTrue(app.buttons["library-import"].exists)
        XCTAssertTrue(app.buttons["library-write"].exists)
    }

    func testFilePickerStaysOpenWhileSearching() {
        let app = XCUIApplication()
        app.launch()
        app.openShelf("Books")
        app.buttons["library-add"].tap()
        let choose = app.buttons["library-import"]
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

    /// Written text belongs to the Library, reads offline and survives relaunch.
    func testTypedTextIsSavedToLibraryWithoutPreparingReaderTransfer() {
        let app = XCUIApplication()
        app.launch()
        app.openShelf("Books")
        app.buttons["library-add"].tap()
        app.buttons["library-write"].tap()
        let title = app.textFields["compose-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let save = app.buttons["compose-save"]
        XCTAssertFalse(save.isEnabled)
        title.tap()
        title.typeText(String(repeating: "x", count: 257))
        let text = app.textViews["compose-text"]
        text.tap()
        text.typeText("An offline reading document.\n\nSecond paragraph.")
        save.tap()
        XCTAssertTrue(app.staticTexts["compose-error"].waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String)?.contains("Second paragraph") == true)
        app.buttons["compose-cancel"].tap()
        app.buttons["library-add"].tap()
        app.buttons["library-write"].tap()
        title.tap()
        let name = "Offline book " + UUID().uuidString.prefix(8)
        title.typeText(name)
        text.tap()
        text.typeText("An offline reading document.\n\nSecond paragraph.")
        save.tap()
        let book = app.buttons["book-" + name]
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["book-transfer-connect"].exists)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.staticTexts["reader-progress"].waitForExistence(timeout: 20))
        attach(app, "qa-written-book-reading")
    }

    func testSystemShareExtensionSavesTextIntoAppLibrary() {
        let app = XCUIApplication()
        let articleTitle = "Shared article " + UUID().uuidString.prefix(8)
        app.launchArguments = ["--ui-test-article-share"]
        app.launch()
        app.buttons["Share selected article text"].tap()
        let destination = app.cells["Pocket Daily"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        // The remote share sheet exposes a container cell as well as its
        // icon. Tap the visible icon so activation targets the actual control.
        let shareIcon = destination.images["activityImageView"]
        XCTAssertTrue(shareIcon.waitForExistence(timeout: 5))
        shareIcon.tap()
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
        app.buttons["Send to Reader…"].firstMatch.tap()
        XCTAssertTrue(app.buttons["book-transfer-connect"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[articleTitle].exists)
        attach(app, "article-library-prepared")
        app.buttons["book-transfer-close"].tap()
        app.terminate()
        app.launch()
        app.openShelf("Articles")
        app.filterArticles("All articles")
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        app.buttons["book-transfer-reopen"].tap()
        XCTAssertTrue(app.staticTexts[articleTitle].waitForExistence(timeout: 5))
        app.buttons["Discard this transfer…"].tap()
        app.buttons["Discard transfer"].tap()
        app.buttons["book-transfer-close"].tap()
        app.buttons["article-options-" + articleTitle].tap()
        app.buttons["Delete"].firstMatch.tap()
        let confirmDelete = app.buttons["Delete " + articleTitle]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: saved)
        XCTAssertEqual(XCTWaiter().wait(for: [removed], timeout: 5), .completed)

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
        app.open("On Reader")
        XCTAssertTrue(app.staticTexts["Example files · a connected reader lists its own"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "inventory-demo").count, 3)
        XCTAssertFalse(app.buttons["inventory-connect"].exists)
        XCTAssertFalse(app.buttons["library-write"].exists, "On Reader must not own ordinary content creation")
        app.openReaderOnlyFiles()
        XCTAssertTrue(app.buttons["reader-only-files-add"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reader-only-files-add"].isEnabled, "Nothing may reach a device")
        // Reader settings are populated in Home & Sleep so they are reviewable...
        app.open("Screens")
        XCTAssertTrue(app.waitForLayoutPreview())
        if app.isCompact {
            let canvas = app.buttons["profile-canvas"]
            XCTAssertTrue(canvas.exists, "The compact preview must expose its enlargement action")
            let originalPreview = canvas.label
            canvas.tap()
            let done = app.buttons["profile-canvas-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5), "Tapping the preview must open its full-size sheet")
            done.tap()
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            XCTAssertEqual(canvas.label, originalPreview, "Closing the preview must preserve the editor's screen")
        }
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
