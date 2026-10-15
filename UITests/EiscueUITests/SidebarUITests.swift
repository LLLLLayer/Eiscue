import XCTest

final class SidebarUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testSidebarIsHorizontalAndSettingsPushesIntoMainNavigation() {
        let app = launch()
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let openButtonFrame = app.buttons["historyButton"].frame
        openSidebar(in: app)
        let settings = app.buttons["sidebarSettingsButton"]
        let newConversation = app.buttons["newConversationButton"]
        XCTAssertTrue(app.staticTexts["No conversations yet"].exists)
        XCTAssertTrue(newConversation.isHittable)
        XCTAssertEqual(settings.label, "Settings", "The icon-only control must retain its full accessible label.")
        XCTAssertEqual(newConversation.label, "New conversation")
        XCTAssertGreaterThanOrEqual(settings.frame.width, 44)
        XCTAssertGreaterThanOrEqual(settings.frame.height, 44)
        XCTAssertEqual(settings.frame.width, openButtonFrame.width, accuracy: 1)
        XCTAssertEqual(settings.frame.height, openButtonFrame.height, accuracy: 1)
        XCTAssertEqual(newConversation.frame.midY, settings.frame.midY, accuracy: 2,
                       "The footer actions must share one horizontal row.")
        XCTAssertLessThan(newConversation.frame.maxX, settings.frame.minX)
        XCTAssertLessThan(newConversation.frame.midX, app.frame.midX,
                          "The sidebar must open at the leading edge, not as a bottom sheet.")
        let close = app.buttons["closeSidebarButton"]
        if close.exists {
            XCTAssertEqual(close.frame.width, settings.frame.width, accuracy: 1)
            XCTAssertEqual(close.frame.height, settings.frame.height, accuracy: 1)
            XCTAssertFalse(app.buttons["deviceNavigationLink"].isHittable, "A compact drawer must hide the underlying controls.")
        }
        attach(app, name: "Sidebar control sizing")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["modelSettingsButton"].isHittable)
        returnToAssistant(in: app)
        XCTAssertTrue(app.buttons["sendMessageButton"].isHittable)
        XCTAssertFalse(app.navigationBars["Settings"].exists)
    }

    @MainActor
    func testWideSidebarCanCollapseAndExpand() throws {
        let app = launch()
        guard app.frame.width >= 820 else { throw XCTSkip("This case checks the persistent sidebar in a wide iPad window.") }
        let settings = app.buttons["sidebarSettingsButton"]
        XCTAssertTrue(settings.isHittable, "A wide window starts with its sidebar visible.")
        XCTAssertFalse(app.buttons["closeSidebarButton"].exists)
        app.buttons["historyButton"].tap()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["deviceNavigationLink"].isHittable)
        app.buttons["historyButton"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
    }

    @MainActor
    func testRightSwipeAcrossBlankChatAreaOpensSidebar() {
        let app = launch()
        hideWideSidebar(in: app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let y = app.buttons["sendMessageButton"].frame.minY - 60
        let start = origin.withOffset(CGVector(dx: app.frame.width * 0.25, dy: y))
        let end = origin.withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end)
        let settings = app.buttons["sidebarSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(app.buttons["newConversationButton"].isHittable)
        let closeStart = origin.withOffset(CGVector(dx: min(280, app.frame.width * 0.7), dy: y))
        let closeEnd = origin.withOffset(CGVector(dx: 12, dy: y))
        closeStart.press(forDuration: 0.05, thenDragTo: closeEnd)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sendMessageButton"].isHittable)
    }

    @MainActor
    func testRightSwipeWithKeyboardPreservesDraftAndSendAppearance() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["EISCUE_TEST_MODEL_URL"] = "http://127.0.0.1:18765/v1"
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))

        for appearance in ["Light", "Dark"] {
            openSettings(in: app)
            app.buttons["appearancePicker"].tap()
            app.buttons[appearance].tap()
            returnToAssistant(in: app)
            hideWideSidebar(in: app)
            let send = app.buttons["sendMessageButton"]
            XCTAssertGreaterThanOrEqual(send.frame.height, 44)
            if appearance == "Light" {
                XCTAssertFalse(send.isEnabled)
                attach(app, name: "White send arrow — disabled, light")
            }
            let input = app.textFields["messageInput"].exists ? app.textFields["messageInput"] : app.textViews["messageInput"]
            input.tap()
            if appearance == "Light" { input.typeText("Keep this draft") }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(send.isEnabled)
            attach(app, name: "White send arrow — enabled, \(appearance)")

            let origin = app.coordinate(withNormalizedOffset: .zero)
            let y = input.frame.minY - 35
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.25, dy: y))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
            start.press(forDuration: 0.05, thenDragTo: end)
            let settings = app.buttons["sidebarSettingsButton"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            XCTAssertTrue(settings.isHittable)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            attach(app, name: "Sidebar after right swipe — \(appearance)")
            let closeStart = origin.withOffset(CGVector(dx: min(280, app.frame.width * 0.7), dy: y))
            let closeEnd = origin.withOffset(CGVector(dx: 12, dy: y))
            closeStart.press(forDuration: 0.05, thenDragTo: closeEnd)
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
            XCTAssertTrue(send.isHittable)
            XCTAssertTrue(send.isEnabled)
            XCTAssertEqual(input.value as? String, "Keep this draft")
            attach(app, name: "Chat after left swipe closes sidebar — \(appearance)")
        }
    }

    @MainActor func testNavigationDismissesKeyboardAndKeepsDraft() {
        let app = launch()
        let input = app.textFields["messageInput"].exists ? app.textFields["messageInput"] : app.textViews["messageInput"]
        input.tap(); input.typeText("Keep navigation draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["deviceNavigationLink"].tap()
        XCTAssertTrue(app.navigationBars["Device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        returnToAssistant(in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String, "Keep navigation draft")
        input.tap()
        app.buttons["conversationMenuButton"].tap()
        app.buttons["conversationRunHistoryButton"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String, "Keep navigation draft")
    }

    @MainActor private func hideWideSidebar(in app: XCUIApplication) {
        let settings = app.buttons["sidebarSettingsButton"]
        if settings.isHittable { app.buttons["historyButton"].tap() }
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
