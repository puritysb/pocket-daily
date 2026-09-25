import XCTest

/// Navigation shared by the flow and screenshot tests. The app shows tabs
/// (Home & Sleep, Cards, Reader) on iPhone and, on wide layouts, a studio
/// switch beside an always-visible Reader inspector.
extension XCUIApplication {
    var isCompact: Bool { tabBars.firstMatch.exists }

    /// Opens a studio section and waits until it is selected. Reader is
    /// always visible beside the studio on wide layouts, so there it only
    /// needs the inspector.
    func open(_ section: String) {
        let tabs = tabBars.firstMatch
        let header = segmentedControls["studio-mode"]
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabs.exists || header.exists }, object: self)
        _ = XCTWaiter().wait(for: [shown], timeout: 10)
        let target: XCUIElement
        if tabs.exists {
            target = tabs.buttons[section]
        } else if section == "Reader" {
            return
        } else {
            target = header.buttons[section]
        }
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

    /// Scrolls the studio (canvas and its controls) until `element` is hittable.
    func revealInStudio(_ element: XCUIElement, attempts: Int = 8) {
        for _ in 0..<attempts where !element.isHittable { swipeUp() }
    }

    /// The Home & Sleep canvas once its frame matches the current edit.
    @discardableResult
    func waitForLayoutPreview(caption: String = "Sample content", timeout: TimeInterval = 15) -> Bool {
        let canvas = descendants(matching: .any)["profile-canvas"]
        let current = NSPredicate(format: "value == %@", "Current")
        let ready = XCTNSPredicateExpectation(predicate: current, object: canvas)
        let captioned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", caption),
            object: descendants(matching: .any)["profile-canvas-caption"])
        return XCTWaiter().wait(for: [ready, captioned], timeout: timeout) == .completed
    }
}
