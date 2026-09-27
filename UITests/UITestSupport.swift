import XCTest

/// Navigation shared by the flow and screenshot tests. The app opens on the
/// Library. iPhone shows tabs (Library, Customize reader, Reader); wide layouts
/// show Library and Customize reader, with the Reader inspector beside the
/// studio. The studio switches between the Home and Sleep screens above its
/// canvas.
extension XCUIApplication {
    /// Only compact layouts give the Reader controls their own tab.
    var isCompact: Bool { tabBars.firstMatch.buttons["Reader"].exists }

    /// Shows the Library's Books or Articles shelf.
    func openShelf(_ shelf: String) {
        open("Library")
        let segment = buttons[shelf].firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        segment.tap()
    }

    /// Opens a section tab and waits until it is selected. Wide layouts have
    /// no Reader tab: the Reader inspector sits beside Customize reader.
    func open(_ section: String) {
        // iPad shows its tabs in a top bar that is not exposed as a tab bar.
        let tabs = tabBars.firstMatch
        let topTab = buttons["Customize reader"].firstMatch
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabs.exists || topTab.exists }, object: self)
        _ = XCTWaiter().wait(for: [shown], timeout: 10)
        let container: XCUIElement = tabs.exists ? tabs : self
        var target = container.buttons[section].firstMatch
        if section == "Reader", !target.exists { target = container.buttons["Customize reader"].firstMatch }
        guard target.exists else { return }
        // A tap during launch can land before the control is interactive.
        for _ in 0..<3 where !target.isSelected {
            target.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isSelected == true"), object: target)], timeout: 3)
        }
    }

    /// Scrolls the surface holding Reader controls until `element` is hittable.
    func revealInReader(_ element: XCUIElement, upward: Bool = false, attempts: Int = 8) {
        let inspector = scrollViews["inspector"]
        let surface: XCUIElement = inspector.exists ? inspector : self
        for _ in 0..<attempts where !element.isHittable {
            if upward { surface.swipeDown() } else { surface.swipeUp() }
        }
    }

    /// Scrolls the studio (canvas and its controls) until `element` is hittable
    /// and clear of the Apply bar pinned at the bottom of compact layouts.
    func revealInStudio(_ element: XCUIElement, attempts: Int = 8) {
        let apply = buttons["profile-apply"]
        func clear() -> Bool {
            guard element.isHittable else { return false }
            guard isCompact, apply.exists else { return true }
            return element.frame.maxY < apply.frame.minY - 24
        }
        for _ in 0..<attempts where !clear() { swipeUp() }
    }

    /// Scrolls the studio back up until the canvas is in view.
    func revealCanvas(attempts: Int = 8) {
        let canvas = descendants(matching: .any)["profile-canvas"]
        for _ in 0..<attempts where !canvas.isHittable { swipeDown() }
    }

    /// Shows the Home or Sleep screen of the studio.
    func openScreen(_ screen: String) {
        revealCanvas()
        let segment = buttons[screen]
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        segment.tap()
    }

    /// Opens My cards under their Home page.
    func openCards() {
        let disclosure = buttons["profile-edit-cards"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        revealInStudio(disclosure)
        disclosure.tap()
    }

    /// The Home & Sleep canvas once its frame matches the current edit.
    @discardableResult
    func waitForLayoutPreview(caption: String = "Demo cards · example book, weather & schedule", timeout: TimeInterval = 15) -> Bool {
        let canvas = descendants(matching: .any)["profile-canvas"]
        let current = NSPredicate(format: "value == %@", "Current")
        let ready = XCTNSPredicateExpectation(predicate: current, object: canvas)
        let captioned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", caption),
            object: descendants(matching: .any)["profile-canvas-caption"])
        return XCTWaiter().wait(for: [ready, captioned], timeout: timeout) == .completed
    }
}
