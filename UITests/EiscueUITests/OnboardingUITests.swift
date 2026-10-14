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
        XCTAssertTrue(app.staticTexts["连接设备"].exists)
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
        XCTAssertTrue(app.staticTexts["Connect your AI"].exists)
        assertGuideHasNoNavigationExit(app)
    }

    @MainActor
    func testLocalVPNOnboardingKeepsComputerHelpInsideTheApp() {
        let app = launchPairingGuide(saved: false)
        let importFile = app.buttons["onboardingImportPairingButton"]
        let help = app.buttons["onboardingConnectionHelpButton"]
        XCTAssertTrue(importFile.waitForExistence(timeout: 5))
        XCTAssertTrue(help.exists)
        XCTAssertFalse(app.buttons["onboardingConnectDeviceButton"].exists,
                       "An unpaired device must not be offered a working VPN connection.")
        XCTAssertFalse(app.buttons["onboardingReconnectPairingButton"].exists)
        assertNoGitHubLinks(app)
        saveScreenshot(app, name: "Onboarding-VPN-Unpaired")

        help.tap()
        assertNativeConnectionHelp(app)
        saveScreenshot(app, name: "Onboarding-VPN-Native-Help")
        app.buttons["onboardingCloseConnectionHelpButton"].tap()
        XCTAssertTrue(importFile.waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(app.buttons["onboardingContinueButton"].isHittable)
        assertGuideHasNoNavigationExit(app)
    }

    @MainActor
    func testSavedPairingIsNotReadyAndCanBeExplicitlyRemoved() {
        let app = launchPairingGuide(saved: true)
        let status = app.staticTexts["onboardingPairingStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "配对已保存")
        XCTAssertFalse(app.staticTexts["devicePairingComplete"].exists)
        XCTAssertTrue(app.buttons["onboardingConnectDeviceButton"].isEnabled)
        XCTAssertFalse(app.buttons["onboardingImportPairingButton"].exists)
        assertNoGitHubLinks(app)
        saveScreenshot(app, name: "Onboarding-VPN-Saved-Pairing")

        app.buttons["onboardingReconnectPairingButton"].tap()
        let remove = app.buttons["移除配对"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        cancelPairingConfirmation(app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "配对已保存", "Cancelling must preserve the saved identity.")

        app.buttons["onboardingReconnectPairingButton"].tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(app.buttons["onboardingImportPairingButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboardingConnectDeviceButton"].exists)
        XCTAssertFalse(app.buttons["onboardingReconnectPairingButton"].exists)
        assertGuideHasNoNavigationExit(app)
    }

    @MainActor
    private func launchPairingGuide(saved: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-state",
                               saved ? "--onboarding-saved-pairing-fixture" : "--onboarding-pairing-fixture",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let next = app.buttons["onboardingContinueButton"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        next.tap()
        let picker = app.buttons["deviceConnectionMethodPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "ESP32-C3 / S3 键鼠")
        picker.tap()
        let localVPN = app.buttons["deviceConnectionChoice_localVPN"]
        XCTAssertTrue(localVPN.waitForExistence(timeout: 5))
        localVPN.tap()
        XCTAssertTrue(localVPN.waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "App 内连接")
        return app
    }

    @MainActor
    private func assertNativeConnectionHelp(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["onboardingConnectionHelp"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboardingCloseConnectionHelpButton"].isHittable)
        let copy = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(copy.contains("电脑"))
        XCTAssertTrue(copy.contains("开发者模式"))
        XCTAssertTrue(copy.contains("配对文件"))
        assertNoGitHubLinks(app)
    }

    @MainActor
    private func assertNoGitHubLinks(_ app: XCUIApplication) {
        XCTAssertFalse(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "github", "github")
        ).firstMatch.exists)
    }

    @MainActor
    private func cancelPairingConfirmation(_ app: XCUIApplication) {
        let cancel = app.buttons["取消"].firstMatch
        if cancel.exists { cancel.tap(); return }
        // iOS 26 presents this confirmation as a popover, omitting its cancel
        // action. Dismiss through the observed region outside that popover.
        let dismiss = app.otherElements["PopoverDismissRegion"]
        let popover = app.popovers.firstMatch
        XCTAssertTrue(dismiss.exists)
        XCTAssertTrue(popover.exists)
        let point = CGPoint(x: dismiss.frame.midX, y: (dismiss.frame.minY + popover.frame.minY) / 2)
        XCTAssertGreaterThan(point.y, app.frame.minY + 60)
        XCTAssertFalse(popover.frame.contains(point))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func assertGuideHasNoNavigationExit(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["onboardingContinueButton"].isHittable)
        // Full-screen presentation can leave underlying controls in the AX tree,
        // including the persistent iPad sidebar. None may be reachable.
        let reachableButtons = app.navigationBars.buttons.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertTrue(reachableButtons.isEmpty,
                      "The unfinished guide exposes navigation controls: \(reachableButtons.map(\.label))")
        for identifier in ["historyButton", "deviceNavigationLink", "newConversationButton", "sidebarSettingsButton", "closeSidebarButton"] {
            XCTAssertFalse(app.buttons[identifier].isHittable, "The guide exposes \(identifier)")
        }
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
