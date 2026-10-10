import XCTest

final class LocalizationUITests: XCTestCase {
    @MainActor
    private func launch(language: String, locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func assertActivitySummary(_ text: String, in app: XCUIApplication) {
        let details = app.descendants(matching: .any).matching(identifier: "backgroundStatusDetails").firstMatch
        reveal(details, in: app)
        details.tap()
        let summary = app.descendants(matching: .any).matching(identifier: "backgroundStatusSummary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        // LabeledContent may expose its value in one combined accessibility
        // label instead of a separate StaticText child.
        XCTAssertTrue(summary.label.contains(text) || (summary.value as? String) == text
                      || summary.staticTexts[text].exists)
    }

    @MainActor
    func testEnglishInterfaceAndOptionalNotifications() {
        let app = launch(language: "en", locale: "en_US")
        XCTAssertTrue(app.tabBars.buttons["Assistant"].exists)
        XCTAssertTrue(app.tabBars.buttons["Device"].exists)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["appLanguageSettingsButton"].exists)
        XCTAssertTrue(app.staticTexts["Model settings"].exists)
        app.buttons["modelSettingsButton"].tap()
        XCTAssertTrue(app.textFields["modelBaseURL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons["Cancel"].exists)
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["taskStatusSettingsButton"].tap()
        let toggle = app.switches["taskNotificationsToggle"]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        assertActivitySummary("System Live Activity", in: app)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Reading settings must not request notification permission.")
    }

    @MainActor
    func testChineseBackgroundSettingsUseResourcesWithoutRequestingPermission() {
        let app = launch(language: "zh-Hans", locale: "zh_CN")
        app.tabBars.buttons["设置"].tap()
        app.buttons["taskStatusSettingsButton"].tap()
        let toggle = app.switches["taskNotificationsToggle"]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        assertActivitySummary("系统实时活动", in: app)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
