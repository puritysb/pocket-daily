import XCTest

/// Navigation shared by the flow and screenshot tests. The app shows tabs
/// (Home & Sleep, Reader) on iPhone and, on wide layouts, the studio beside an
/// always-visible Reader inspector. The studio switches between the Home and
/// Sleep screens above its canvas.
extension XCUIApplication {
    var isCompact: Bool { tabBars.firstMatch.exists }

    /// Opens a studio section (a tab on iPhone) and waits until it is selected.
    /// Wide layouts show Home & Sleep and the Reader inspector side by side.
    func open(_ section: String) {
        let tabs = tabBars.firstMatch
        let canvas = descendants(matching: .any)["profile-canvas"]
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabs.exists || canvas.exists }, object: self)
        _ = XCTWaiter().wait(for: [shown], timeout: 10)
        guard tabs.exists else { return }
        let target = tabs.buttons[section]
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
    func waitForLayoutPreview(caption: String = "Your cards · sample content", timeout: TimeInterval = 15) -> Bool {
        let canvas = descendants(matching: .any)["profile-canvas"]
        let current = NSPredicate(format: "value == %@", "Current")
        let ready = XCTNSPredicateExpectation(predicate: current, object: canvas)
        let captioned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", caption),
            object: descendants(matching: .any)["profile-canvas-caption"])
        return XCTWaiter().wait(for: [ready, captioned], timeout: timeout) == .completed
    }
}
