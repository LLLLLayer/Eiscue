import XCTest

final class DevicePageUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-state", "--skip-onboarding", "--local-device-ready-fixture",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["devicePairingComplete"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testReadyConnectionShowsInlineDisconnectAndScreenPreview() {
        let app = launch()
        let ready = app.staticTexts["devicePairingComplete"]
        let subtitle = app.staticTexts["deviceVPNUsage"]
        let disconnect = app.buttons["disconnectDeviceButton"]
        XCTAssertTrue(subtitle.exists)
        XCTAssertTrue(subtitle.label.contains("VPN"))
        XCTAssertTrue(disconnect.isHittable)
        XCTAssertGreaterThanOrEqual(disconnect.frame.minX, ready.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(disconnect.frame.midY, ready.frame.minY)
        XCTAssertLessThanOrEqual(disconnect.frame.midY, subtitle.frame.maxY)
        XCTAssertFalse(app.otherElements["deviceAdvancedOptions"].exists)

        let preview = app.buttons["deviceScreenPreviewButton"]
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["deviceScreenPreviewImage"].waitForExistence(timeout: 5))
        app.buttons["closeDeviceScreenPreviewButton"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.isHittable)
    }

    @MainActor
    func testConnectionOptionsKeepManualInputCheckAvailable() {
        let app = launch()
        app.buttons["deviceConnectionOptionsMenu"].tap()
        XCTAssertTrue(app.buttons["deviceConnectionHelpButton"].waitForExistence(timeout: 5))
        app.buttons["deviceProbeButton"].tap()
        let increment = app.buttons["probeIncrement"]
        XCTAssertTrue(increment.waitForExistence(timeout: 5))
        increment.tap()
        XCTAssertEqual(app.staticTexts["probeCount"].label, "计数：1")
        let input = app.textFields["probeInput"]
        input.tap()
        input.typeText("Eiscue UI")
        XCTAssertEqual(app.staticTexts["probeEcho"].label, "Eiscue UI")
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["devicePairingComplete"].waitForExistence(timeout: 5))
    }
}
