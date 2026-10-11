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
        openSidebar(in: app)
        let settings = app.buttons["sidebarSettingsButton"]
        XCTAssertTrue(app.staticTexts["No conversations yet"].exists)
        XCTAssertTrue(app.buttons["newConversationButton"].isHittable)
        XCTAssertLessThan(settings.frame.midX, app.frame.midX, "The sidebar must open at the leading edge, not as a bottom sheet.")
        if app.buttons["closeSidebarButton"].exists {
            XCTAssertFalse(app.buttons["deviceNavigationLink"].isHittable, "A compact drawer must hide the underlying controls.")
        }
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
}
