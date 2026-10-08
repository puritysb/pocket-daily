import XCTest

/// Walks the screens a first-time user meets without a reader, then the same
/// companion screens in demo mode, and keeps a screenshot of each step. The
/// captures feed UI/UX review; names start with `qa-tour`, so the store
/// capture script skips them. Optional steps never fail the walk.
final class PocketQATourTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "qa-tour-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFirstRunWithoutReader() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fresh-library", "--ui-test-empty-discovery"]
        app.launch()
        XCTAssertTrue(app.buttons["book-Welcome to Pocket Daily"].waitForExistence(timeout: 15))
        attach(app, "01-library")

        let add = app.buttons["library-add"]
        if add.exists {
            add.tap()
            attach(app, "02-library-add-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6)).tap()
        }

        let book = app.buttons["book-Welcome to Pocket Daily"]
        book.press(forDuration: 1)
        attach(app, "03-book-menu")
        let send = app.buttons["send-book-to-reader"]
        if send.waitForExistence(timeout: 3) {
            send.tap()
            _ = app.buttons["book-transfer-connect"].waitForExistence(timeout: 10)
            attach(app, "04-send-sheet")
            if app.buttons["book-transfer-connect"].exists {
                app.buttons["book-transfer-connect"].tap()
                sleep(1)
                attach(app, "05-send-connect")
                if app.buttons["book-transfer-connection-back"].exists { app.buttons["book-transfer-connection-back"].tap() }
            }
            if app.buttons["book-transfer-close"].waitForExistence(timeout: 3) { app.buttons["book-transfer-close"].tap() }
            attach(app, "06-library-with-pending-task")
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6)).tap()
        }

        book.tap()
        let page = app.descendants(matching: .any)["reader-page"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Ready"), object: page)
        _ = XCTWaiter().wait(for: [ready], timeout: 20)
        attach(app, "07-reader")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.buttons["reader-close"].waitForExistence(timeout: 5)
        attach(app, "08-reader-chrome")
        let appearance = app.buttons["reader-appearance"]
        if appearance.exists {
            appearance.tap()
            sleep(1)
            attach(app, "09-reader-appearance")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            sleep(1)
        }
        if !app.buttons["reader-close"].exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        if app.buttons["reader-close"].waitForExistence(timeout: 5) { app.buttons["reader-close"].tap() }
        _ = app.buttons["continue-reading"].waitForExistence(timeout: 10)
        attach(app, "10-library-after-reading")

        app.open("My Reader")
        sleep(1)
        attach(app, "11-my-reader")
        for (index, destination) in ["On Reader", "Screens", "Reading", "Device"].enumerated() {
            app.open(destination)
            sleep(2)
            attach(app, "\(12 + index)-\(destination.replacingOccurrences(of: " ", with: "-").lowercased())")
        }
        app.open("My Reader")
        let connect = app.buttons["overview-connect"]
        if connect.waitForExistence(timeout: 5) {
            connect.tap()
            sleep(1)
            attach(app, "16-connect")
            let find = app.buttons["Find on same Wi-Fi"]
            if find.exists {
                find.tap()
                sleep(6)
                attach(app, "17-connect-not-found")
            }
        }
        app.terminate()

        app.launch()
        app.openSettings()
        sleep(1)
        attach(app, "18-settings")
    }

    func testDemoCompanion() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--hardware=X3", "--ui-test-fresh-library"]
        app.launch()
        app.open("My Reader")
        sleep(1)
        attach(app, "demo-01-my-reader")
        app.open("On Reader")
        sleep(2)
        attach(app, "demo-02-on-reader")
        app.open("Screens")
        _ = app.waitForLayoutPreview()
        attach(app, "demo-03-screens-home")
        let canvas = app.descendants(matching: .any)["profile-canvas"]
        if app.isCompact, canvas.exists {
            canvas.tap()
            if app.buttons["profile-canvas-done"].waitForExistence(timeout: 5) {
                sleep(1)
                attach(app, "demo-03b-enlarged-preview")
                app.buttons["profile-canvas-done"].tap()
            }
        }
        app.openScreen("Sleep")
        sleep(2)
        attach(app, "demo-04-screens-sleep")
        app.openWeatherAndCalendar()
        sleep(1)
        attach(app, "demo-05-weather-calendar")
        if app.buttons["content-editor-close"].exists { app.buttons["content-editor-close"].tap() }
        app.open("Reading")
        sleep(2)
        attach(app, "demo-06-reading")
        app.open("Device")
        sleep(1)
        attach(app, "demo-07-device")
    }
}
