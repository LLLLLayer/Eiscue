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
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        XCTAssertFalse(app.buttons["removePairingButton"].exists,
                       "Re-pairing belongs to the disconnected state, not the ready controls.")
        XCTAssertFalse(app.buttons["copyComputerPairingCommandButton"].exists,
                       "A ready device should not repeat the initial computer setup.")
        saveScreenshot(app, name: "Device-Ready-Inline")

        let preview = app.buttons["deviceScreenPreviewButton"]
        XCTAssertTrue(preview.isHittable)
        preview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["deviceScreenPreviewImage"].waitForExistence(timeout: 5))
        app.buttons["closeDeviceScreenPreviewButton"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.isHittable)
        disconnect.tap()
        XCTAssertTrue(app.buttons["removePairingButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(ready.label, "配对已保存")
        XCTAssertTrue(app.buttons["connectDeviceButton"].exists)
        XCTAssertFalse(preview.exists)
        XCTAssertFalse(app.buttons["deviceProbeButton"].exists)
    }

    @MainActor
    func testDebugSectionKeepsManualInputCheckBelowReadyConnection() {
        let app = launch()
        XCTAssertFalse(app.buttons["deviceConnectionOptionsMenu"].exists)
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        let debugTitle = app.staticTexts["deviceDebugSectionTitle"]
        let probe = app.buttons["deviceProbeButton"]
        for _ in 0..<3 where !probe.isHittable { app.swipeUp() }
        XCTAssertTrue(debugTitle.exists)
        XCTAssertEqual(debugTitle.label, "调试")
        XCTAssertGreaterThan(debugTitle.frame.minY, app.buttons["deviceScreenPreviewButton"].frame.maxY)
        XCTAssertGreaterThan(probe.frame.minY, debugTitle.frame.maxY)
        XCTAssertTrue(probe.isHittable)
        probe.tap()
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

    @MainActor
    func testConnectionChoicesShowChipsetSummariesWithoutChangingDefaultRoute() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-state", "--skip-onboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openDevice(in: app)
        let picker = app.buttons["deviceConnectionMethodPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "App 内连接")
        picker.tap()
        let appMethod = app.buttons["deviceConnectionChoice_localVPN"]
        let bluetooth = app.buttons["deviceConnectionChoice_bluetoothBoard"]
        let usb = app.buttons["deviceConnectionChoice_usbBoard"]
        let wifi = app.buttons["deviceConnectionChoice_wirelessBoard"]
        XCTAssertTrue(appMethod.waitForExistence(timeout: 5))
        XCTAssertTrue(bluetooth.exists)
        XCTAssertTrue(usb.exists)
        XCTAssertTrue(wifi.exists)
        XCTAssertLessThan(appMethod.frame.minY, bluetooth.frame.minY)
        XCTAssertLessThan(bluetooth.frame.minY, usb.frame.minY)
        XCTAssertLessThan(usb.frame.minY, wifi.frame.minY)
        XCTAssertEqual(appMethod.value as? String, "已选用")
        XCTAssertNotEqual(bluetooth.value as? String, "已选用")
        XCTAssertEqual(usb.label, "ESP32-S3 USB 网卡")
        XCTAssertEqual(wifi.label, "ESP32-C3 Wi-Fi")
        appMethod.tap()
        XCTAssertTrue(appMethod.waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "App 内连接")
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        XCTAssertTrue(app.buttons["copyComputerPairingCommandButton"].exists)
        XCTAssertTrue(app.buttons["importPairingIdentityButton"].exists)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        XCTAssertFalse(app.buttons["connectDeviceButton"].exists)
        XCTAssertFalse(app.buttons["deviceProbeButton"].exists, "An unready route must not expose the input check.")
        XCTAssertFalse(app.buttons["deviceConnectionOptionsMenu"].exists)
        saveScreenshot(app, name: "Device-Unpaired-Inline")

        picker.tap()
        XCTAssertTrue(bluetooth.waitForExistence(timeout: 5))
        bluetooth.tap()
        XCTAssertTrue(bluetooth.waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "ESP32-C3 / S3 键鼠")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-state" }
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openDevice(in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "ESP32-C3 / S3 键鼠",
                       "The initial in-app default must not replace a saved connection choice.")
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
