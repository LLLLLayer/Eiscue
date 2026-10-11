import XCTest

final class OnboardingUITests: XCTestCase {
    @MainActor
    func testFirstLaunchGuideIsFullScreenAndCompletionPersists() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-state", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let next = app.buttons["onboardingContinueButton"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["你好，我是 Eiscue。"].exists)
        assertGuideHasNoNavigationExit(app)
        saveScreenshot(app, name: "Onboarding-Chinese-Light")
        next.tap()
        XCTAssertTrue(app.buttons["onboardingConfigureModel"].exists)
        assertGuideHasNoNavigationExit(app)
        next.tap()
        XCTAssertTrue(app.staticTexts["准备好你的设备。"].exists)
        assertGuideHasNoNavigationExit(app)
        XCTAssertFalse(app.buttons["startPairingButton"].exists, "iOS 26 must not offer the iOS 27 system flow.")
        saveScreenshot(app, name: "Onboarding-Device-Chinese")
        next.tap()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-state" }
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(next.exists)
    }

    @MainActor
    func testEnglishGuideCanOpenAndReturnFromModelSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let next = app.buttons["onboardingContinueButton"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Hello, I’m Eiscue."].exists)
        assertGuideHasNoNavigationExit(app)
        saveScreenshot(app, name: "Onboarding-English")
        next.tap()
        assertGuideHasNoNavigationExit(app)
        app.buttons["onboardingConfigureModel"].tap()
        XCTAssertTrue(app.textFields["modelIdentifier"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connect your AI."].exists)
        assertGuideHasNoNavigationExit(app)
    }

    @MainActor
    private func assertGuideHasNoNavigationExit(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["onboardingContinueButton"].isHittable)
        // The full-screen cover can leave Assistant's history/new-conversation
        // buttons in the accessibility tree. Only exposed controls can exit the guide.
        let reachableButtons = app.navigationBars.buttons.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertTrue(reachableButtons.isEmpty,
                      "The unfinished guide exposes navigation controls: \(reachableButtons.map(\.label))")
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
