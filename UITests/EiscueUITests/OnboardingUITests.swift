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
        saveScreenshot(app, name: "Onboarding-Chinese-Light")
        next.tap()
        XCTAssertTrue(app.buttons["onboardingConfigureModel"].exists)
        next.tap()
        XCTAssertTrue(app.staticTexts["准备好你的设备。"].exists)
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
        saveScreenshot(app, name: "Onboarding-English")
        next.tap()
        app.buttons["onboardingConfigureModel"].tap()
        XCTAssertTrue(app.textFields["modelIdentifier"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connect your AI."].exists)
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
