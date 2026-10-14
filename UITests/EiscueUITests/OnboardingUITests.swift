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
        XCTAssertEqual(app.buttons["deviceConnectionMethodPicker"].value as? String, "App 内连接")
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
    func testLocalVPNOnboardingShowsSetupAndCopiesCompleteCommandInline() {
        let app = launchPairingGuide(saved: false)
        let importFile = app.buttons["onboardingImportPairingButton"]
        XCTAssertTrue(importFile.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboardingConnectionHelpButton"].exists)
        XCTAssertFalse(app.buttons["onboardingConnectDeviceButton"].exists,
                       "An unpaired device must not be offered a working VPN connection.")
        XCTAssertFalse(app.buttons["onboardingReconnectPairingButton"].exists)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        assertNoExternalSetupLinks(app)
        let copyCommand = app.buttons["copyComputerPairingCommandButton"]
        XCTAssertTrue(copyCommand.exists, "Copying the setup command must not require a separate help page.")
        XCTAssertFalse(app.buttons["showComputerPairingCommandButton"].exists)
        let steps = (1...5).map { app.staticTexts["pairingSetupStep\($0)"] }
        for step in steps { XCTAssertTrue(step.exists) }
        for index in 1..<steps.count {
            XCTAssertGreaterThan(steps[index].frame.minY, steps[index - 1].frame.maxY)
        }
        saveScreenshot(app, name: "Onboarding-VPN-Five-Steps-Top")

        let command = app.staticTexts["computerPairingCommand"]
        XCTAssertTrue(command.exists, "The full code block must appear without another disclosure action.")
        let completeCommand = command.label
        XCTAssertTrue(completeCommand.contains("git clone"))
        XCTAssertTrue(completeCommand.contains("mktemp"))
        XCTAssertTrue(completeCommand.contains("setup-device.py"))
        XCTAssertTrue(completeCommand.contains("python3"))
        XCTAssertNotEqual(completeCommand, "python3 Scripts/setup-device.py")
        XCTAssertFalse(app.buttons["onboardingCloseConnectionHelpButton"].exists)
        assertGuideHasNoNavigationExit(app)
        let footer = app.buttons["onboardingContinueButton"]
        for _ in 0..<5 where command.frame.maxY >= footer.frame.minY - 12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        XCTAssertLessThan(command.frame.maxY, footer.frame.minY)
        XCTAssertGreaterThan(command.frame.minY, app.frame.minY + 60)
        XCTAssertTrue(copyCommand.isHittable)
        XCTAssertEqual(copyCommand.label, "复制命令")
        saveScreenshot(app, name: "Onboarding-VPN-Computer-Command")
        copyCommand.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已复制"), object: copyCommand)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 3), .completed)
        assertNoExternalSetupLinks(app)
        saveScreenshot(app, name: "Onboarding-VPN-Command-Copied")
        // SwiftUI may report off-screen scroll content as hittable. Check its
        // visible position instead before recording the lower setup steps.
        for _ in 0..<4 where steps[4].frame.maxY >= footer.frame.minY - 80 { app.swipeUp() }
        XCTAssertTrue(steps[4].isHittable)
        XCTAssertLessThan(steps[4].frame.maxY, footer.frame.minY - 80)
        XCTAssertGreaterThan(steps[3].frame.minY, app.frame.minY + 60)
        XCTAssertTrue(importFile.isHittable)
        saveScreenshot(app, name: "Onboarding-VPN-Five-Steps-Bottom")
        XCTAssertTrue(app.buttons["onboardingContinueButton"].isHittable)
        assertGuideHasNoNavigationExit(app)

        // Paste inside the same isolated app instead of relying on the
        // simulator's host clipboard bridge. The draft is never sent.
        app.buttons["onboardingContinueButton"].tap()
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.press(forDuration: 1)
        let pasteLabel = NSPredicate(format: "label IN %@", ["粘贴", "Paste"])
        let pasteItem = app.menuItems.matching(pasteLabel).firstMatch
        if pasteItem.waitForExistence(timeout: 3) {
            pasteItem.tap()
        } else {
            let pasteButton = app.buttons.matching(pasteLabel).firstMatch
            XCTAssertTrue(pasteButton.waitForExistence(timeout: 3))
            pasteButton.tap()
        }
        XCTAssertEqual(input.value as? String, completeCommand)
        saveScreenshot(app, name: "Onboarding-VPN-Command-Paste-Readback")
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
        assertNoExternalSetupLinks(app)
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
        XCTAssertTrue(app.buttons["copyComputerPairingCommandButton"].exists)
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
        XCTAssertEqual(picker.value as? String, "App 内连接")
        return app
    }

    @MainActor
    private func assertNoExternalSetupLinks(_ app: XCUIApplication) {
        // The copyable shell command includes the repository URL, but setup
        // should never send the user to an external GitHub page.
        let github = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "github", "github")
        XCTAssertFalse(app.links.matching(github).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(github).firstMatch.exists)
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
