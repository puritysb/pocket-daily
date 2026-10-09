import XCTest

/// Navigation shared by flow and screenshot tests. Library and My Reader are
/// peers; reader settings and management open inside the reader workspace.
extension XCUIApplication {
    /// iPad may place native tabs in a floating top bar. Detect the shipping
    /// sidebar rather than assuming every TabView is exposed as an AXTabBar.
    var isCompact: Bool { !buttons["navigation-Books"].exists }

    /// Opens Settings: the sidebar's button on wide layouts, the Library
    /// header's on iPhone.
    func openSettings() {
        if isCompact { open("Library") }
        let settings = buttons["app-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
    }

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

    /// Opens the shipping hierarchy rather than assuming a sidebar per feature.
    func open(_ destination: String) {
        let library = destination == "Library"
        let sidebar = buttons[library ? "navigation-Books" : "navigation-My Reader"]
        let tabName = library ? "Library" : "My Reader"
        let bottomTab = tabBars.firstMatch.buttons[tabName]
        let tab = bottomTab.exists ? bottomTab : buttons[tabName].firstMatch
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tab.exists || sidebar.exists }, object: self)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 15), .completed)
        if sidebar.exists { sidebar.tap() }
        else {
            select(tab)
            if !library {
                let back = navigationBars.buttons["My Reader"].firstMatch
                if back.exists { back.tap() }
            }
        }
        if destination == "Reader Settings" {
            let entry = buttons["reader-settings"]
            revealInReader(entry, upward: true)
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
            entry.tap()
        } else if destination == "Manage Reader" {
            let menu = buttons["reader-management-menu"]
            revealInReader(menu, upward: true)
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            let entry = buttons["reader-manage"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
            entry.tap()
        }
    }

    func openReaderOnlyFiles() {
        let disclosure = buttons["reader-only-files"]
        revealInReader(disclosure)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        if !buttons["reader-only-files-add"].exists { disclosure.tap() }
    }

    func openOtherConnectionMethods() {
        let other = buttons["connection-other-methods"]
        revealInReader(other)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        if other.value as? String != "Expanded" { other.tap() }
    }

    private func select(_ target: XCUIElement) {
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
        let content = descendants(matching: .any)["content-editor-sheet"].exists
        let apply = content
            ? (buttons["content-editor-connect"].exists ? buttons["content-editor-connect"] : buttons["content-editor-apply"])
            : (buttons["profile-connect"].exists ? buttons["profile-connect"] : buttons["profile-apply"])
        let controls = scrollViews["card-editor-controls"].exists ? scrollViews["card-editor-controls"]
            : scrollViews["glance-editor-controls"].exists ? scrollViews["glance-editor-controls"] : scrollViews["profile-controls"]
        func clear() -> Bool {
            guard element.isHittable else { return false }
            guard isCompact, apply.exists else { return true }
            return element.frame.maxY < apply.frame.minY - 24
        }
        for _ in 0..<attempts {
            if clear() { return }
            // The preview stays fixed. Move only part of the shorter settings
            // pane, so a quick swipe cannot skip a row entirely.
            let visible = controls.frame.intersection(frame)
            let bottom = apply.exists ? min(visible.maxY, apply.frame.minY - 12) : visible.maxY
            let top = visible.minY + 8
            let height = max(20, bottom - top)
            let above = element.exists && !element.frame.isEmpty && element.frame.midY < top
            let origin = coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.minX + 8, dy: top + height * (above ? 0.25 : 0.75)))
            let end = origin.withOffset(CGVector(dx: visible.minX + 8, dy: top + height * (above ? 0.75 : 0.25)))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
    }

    /// Scrolls the studio back up until the canvas is in view.
    func revealCanvas(attempts: Int = 8) {
        let canvas = descendants(matching: .any)["card-editor-canvas"].exists
            ? descendants(matching: .any)["card-editor-canvas"] : descendants(matching: .any)["profile-canvas"]
        for _ in 0..<attempts where !canvas.isHittable { swipeDown() }
    }

    func chooseMenu(_ identifier: String, option: String) {
        let menu = buttons[identifier]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    /// All three scopes live in Reader settings, including reading preferences.
    func openScreen(_ screen: String) {
        if !buttons["reader-setting-scope"].exists { open("Reader Settings") }
        let selector = buttons["reader-setting-scope"]
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        selector.tap()
        let option = buttons[screen == "Reading" ? "Reading Preferences" : screen + " Screen"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    /// Opens a dedicated source editor; the parent's Home/Sleep preview stays put.
    func openCards() {
        let action = buttons["profile-edit-cards"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        revealInStudio(action)
        action.tap()
        XCTAssertTrue(descendants(matching: .any)["content-editor-sheet"].waitForExistence(timeout: 10))
        let firstCard = buttons["cards-card-0"]
        revealInStudio(firstCard)
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        firstCard.tap()
    }

    func openWeatherAndCalendar() {
        let action = buttons["screen-glance-settings"]
        revealInStudio(action)
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
        XCTAssertTrue(descendants(matching: .any)["content-editor-sheet"].waitForExistence(timeout: 10))
    }

    @discardableResult
    func waitForCardPreview(timeout: TimeInterval = 15) -> Bool {
        let canvas = descendants(matching: .any)["card-editor-canvas"]
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Current"), object: canvas)], timeout: timeout) == .completed
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
