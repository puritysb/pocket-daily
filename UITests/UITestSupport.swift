import XCTest

/// Navigation shared by the flow and screenshot tests. The app opens on the
/// Library. iPhone shows tabs (Library, Screens, Device); wide layouts
/// show Books, Articles, Screens and Device in a sidebar. The studio switches between the Home and Sleep screens above its
/// canvas.
extension XCUIApplication {
    /// Compact layouts use tabs instead of the sidebar.
    var isCompact: Bool { tabBars.firstMatch.buttons["Device"].exists }

    /// Shows the Library's Books or Articles shelf.
    func openShelf(_ shelf: String) {
        open("Library")
        let sidebarItem = buttons["navigation-\(shelf)"]
        if sidebarItem.exists {
            sidebarItem.tap()
        } else {
            let menu = buttons["library-shelf"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            menu.tap()
            let choice = collectionViews.buttons[shelf].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
        }
    }

    /// Compact layouts use tabs; wide layouts use the navigation sidebar.
    func open(_ section: String) {
        let tabs = tabBars.firstMatch
        let sidebarLabel = section == "Library" ? "Books" : section
        let sidebarItem = buttons["navigation-\(sidebarLabel)"]
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabs.buttons[section].exists || sidebarItem.exists }, object: self)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 15), .completed)
        let target = sidebarItem.exists ? sidebarItem : tabs.buttons[section].firstMatch
        XCTAssertTrue(target.exists, "Missing navigation item: \(section)")
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

    /// Scrolls the settings pane until `element` is hittable
    /// and clear of the Apply bar pinned at the bottom of compact layouts.
    func revealInStudio(_ element: XCUIElement, attempts: Int = 16) {
        let apply = buttons["profile-apply"]
        let controls = scrollViews["profile-controls"]
        func clear() -> Bool {
            guard element.isHittable else { return false }
            guard isCompact, apply.exists else { return true }
            return element.frame.maxY < apply.frame.minY - 24
        }
        for _ in 0..<attempts where !clear() {
            // The preview stays fixed. Move only part of the shorter settings
            // pane, so a quick swipe cannot skip a row entirely.
            let above = element.exists && !element.frame.isEmpty && element.frame.midY < controls.frame.minY
            let start = controls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.3 : 0.7))
            let end = controls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
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


extension XCUIApplication {
    func filterArticles(_ title: String) {
        buttons["article-filter"].tap()
        let option = collectionViews.buttons[title].firstMatch
        if option.waitForExistence(timeout: 3) { option.tap() }
        else { buttons[title].firstMatch.tap() }
    }

    func openSubscriptions() {
        buttons["article-add-menu"].tap()
        buttons["article-subscriptions"].tap()
        XCTAssertTrue(textFields["feed-url"].waitForExistence(timeout: 5))
    }
}
