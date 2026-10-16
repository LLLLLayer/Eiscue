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
        let initialStatusFrame = ready.frame
        let subtitle = app.staticTexts["deviceVPNUsage"]
        let disconnect = app.buttons["disconnectDeviceButton"]
        let permission = app.switches["deviceControlToggle"]
        let method = app.buttons["deviceConnectionMethodPicker"]
        let backend = app.buttons["deviceControlBackendPicker"]
        XCTAssertTrue(subtitle.exists)
        XCTAssertTrue(subtitle.label.contains("VPN"))
        XCTAssertTrue(disconnect.isHittable)
        XCTAssertGreaterThanOrEqual(disconnect.frame.minX, ready.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(disconnect.frame.midY, ready.frame.minY)
        XCTAssertLessThanOrEqual(disconnect.frame.midY, subtitle.frame.maxY)
        XCTAssertFalse(app.otherElements["deviceAdvancedOptions"].exists)
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        XCTAssertTrue(permission.isHittable)
        XCTAssertLessThan(permission.frame.maxY, method.frame.minY)
        XCTAssertLessThan(method.frame.maxY, backend.frame.minY + 1)
        XCTAssertLessThan(backend.frame.maxY, ready.frame.minY)
        XCTAssertFalse(app.buttons["devicePairingSetupButton"].exists)
        XCTAssertFalse(app.buttons["preparePairingButton"].exists)
        let removePairing = app.buttons["removePairingButton"]
        XCTAssertTrue(removePairing.exists)
        XCTAssertFalse(removePairing.isEnabled, "Pairing stays visible, but a ready connection must be disconnected before pairing again.")
        XCTAssertFalse(app.buttons["copyComputerPairingCommandButton"].exists,
                       "A ready device should not repeat the initial computer setup.")
        saveScreenshot(app, name: "Device-Ready-Compact")

        let preview = app.buttons["deviceScreenPreviewButton"]
        revealDeviceElement(preview, in: app)
        preview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["deviceScreenPreviewImage"].waitForExistence(timeout: 5))
        app.buttons["closeDeviceScreenPreviewButton"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        for _ in 0..<5 where abs(ready.frame.minY - initialStatusFrame.minY) > 1 {
            app.scrollViews.firstMatch.swipeDown()
        }
        assertUnchangedFrame(ready, from: initialStatusFrame, context: "Return to the initial scroll position before comparing settings")
        let settings = [permission, method, backend]
        for setting in settings { XCTAssertTrue(setting.exists) }
        let frames = settings.map(\.frame)
        XCTAssertLessThan(settings[0].frame.maxY, settings[1].frame.minY + 1)
        XCTAssertLessThan(settings[1].frame.maxY, settings[2].frame.minY + 1)
        XCTAssertTrue(disconnect.isHittable)
        disconnect.tap()
        XCTAssertTrue(app.buttons["connectDeviceButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(ready.label, "未连接")
        XCTAssertFalse(app.buttons["devicePairingSetupButton"].exists)
        XCTAssertFalse(app.buttons["preparePairingButton"].exists)
        for (setting, frame) in zip(settings, frames) {
            assertUnchangedFrame(setting, from: frame, context: "Disconnect keeps \(setting.identifier) in place")
        }
        XCTAssertFalse(preview.exists)
        XCTAssertFalse(app.buttons["deviceProbeButton"].exists)
        saveScreenshot(app, name: "Device-Disconnected-Compact")
        XCTAssertTrue(removePairing.exists)
        XCTAssertTrue(removePairing.isEnabled)
    }

    @MainActor
    func testDebugSectionGroupsDiagnosticsAndPersistsVisibilitySetting() {
        let app = launch()
        XCTAssertFalse(app.buttons["deviceConnectionOptionsMenu"].exists)
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        let debugTitle = app.staticTexts["deviceDebugSectionTitle"]
        let probe = app.buttons["deviceProbeButton"]
        for _ in 0..<3 where !probe.isHittable { app.swipeUp() }
        XCTAssertTrue(debugTitle.exists)
        XCTAssertEqual(debugTitle.label, "调试")
        XCTAssertGreaterThan(app.buttons["deviceScreenPreviewButton"].frame.minY, debugTitle.frame.maxY)
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

        openSettings(in: app)
        let toggle = app.switches["debugToolsToggle"]
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "1")
        saveScreenshot(app, name: "Settings-Debug-On")
        // SwiftUI exposes the whole labelled row as a switch. Its center is
        // the label, so tap the actual trailing control and verify the value.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        saveScreenshot(app, name: "Settings-Debug-Off")
        XCTAssertEqual(toggle.value as? String, "0")
        openDevice(in: app)
        XCTAssertTrue(app.staticTexts["devicePairingComplete"].exists)
        XCTAssertFalse(debugTitle.exists)
        XCTAssertFalse(probe.exists)
        XCTAssertFalse(app.buttons["deviceScreenPreviewButton"].exists)

        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-state" }
        app.launch()
        XCTAssertTrue(app.staticTexts["devicePairingComplete"].waitForExistence(timeout: 10))
        XCTAssertFalse(debugTitle.exists, "A saved off choice must survive relaunching a Debug build.")
        XCTAssertFalse(app.buttons["deviceScreenPreviewButton"].exists)

        openSettings(in: app)
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        openDevice(in: app)
        XCTAssertTrue(debugTitle.exists)
        XCTAssertTrue(probe.exists)
        XCTAssertTrue(app.buttons["deviceScreenPreviewButton"].exists)
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
        XCTAssertLessThan(app.switches["deviceControlToggle"].frame.maxY, picker.frame.minY)
        picker.tap()
        let appMethod = app.buttons["deviceConnectionChoice_localVPN"]
        let bluetooth = app.buttons["deviceConnectionChoice_bluetoothBoard"]
        let usb = app.buttons["deviceConnectionChoice_usbBoard"]
        XCTAssertTrue(appMethod.waitForExistence(timeout: 5))
        XCTAssertTrue(bluetooth.exists)
        XCTAssertTrue(usb.exists)
        XCTAssertFalse(app.buttons["deviceConnectionChoice_wirelessBoard"].exists)
        XCTAssertLessThan(appMethod.frame.minY, bluetooth.frame.minY)
        XCTAssertLessThan(bluetooth.frame.minY, usb.frame.minY)
        XCTAssertEqual(appMethod.value as? String, "已选用")
        XCTAssertNotEqual(bluetooth.value as? String, "已选用")
        XCTAssertEqual(usb.label, "ESP32-S3 USB 网卡")
        appMethod.tap()
        XCTAssertTrue(appMethod.waitForNonExistence(timeout: 5))
        waitForValue("App 内连接", of: picker)
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        XCTAssertFalse(app.buttons["devicePairingSetupButton"].exists)
        XCTAssertFalse(app.buttons["preparePairingButton"].exists)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        XCTAssertFalse(app.buttons["connectDeviceButton"].exists)
        XCTAssertFalse(app.buttons["deviceProbeButton"].exists, "An unready route must not expose the input check.")
        XCTAssertFalse(app.buttons["deviceConnectionOptionsMenu"].exists)
        saveScreenshot(app, name: "Device-Unpaired-Inline")
        XCTAssertTrue(app.buttons["importPairingIdentityButton"].exists)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            XCTAssertTrue(app.buttons["startPairingButton"].exists)
            XCTAssertFalse(app.buttons["copyComputerPairingCommandButton"].exists)
        } else {
            XCTAssertTrue(app.buttons["copyComputerPairingCommandButton"].exists)
            XCTAssertFalse(app.buttons["startPairingButton"].exists)
        }
        openSettings(in: app)
        let debugToggle = app.switches["debugToolsToggle"]
        for _ in 0..<3 where !debugToggle.isHittable { app.swipeUp() }
        XCTAssertTrue(debugToggle.isHittable)
        debugToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(debugToggle.value as? String, "0")
        openDevice(in: app)
        picker.tap()
        XCTAssertTrue(bluetooth.waitForExistence(timeout: 5))
        bluetooth.tap()
        XCTAssertTrue(bluetooth.waitForNonExistence(timeout: 5))
        waitForValue("ESP32-C3 / S3 键鼠", of: picker)
        XCTAssertTrue(app.buttons["bluetoothVerifyButton"].exists,
                      "Required first calibration stays available with diagnostics hidden.")
        XCTAssertFalse(app.staticTexts["deviceDebugSectionTitle"].exists)
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
    func testIOS27UnpairedSetupIsReachableInEnglishAndDarkAppearance() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This case checks system-pairing presentation on a simulator without starting pairing or VPN.")
        #else
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            throw XCTSkip("The inline system-pairing setup requires iOS 27.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-state", "--skip-onboarding",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openSettings(in: app)
        let appearance = app.buttons["appearancePicker"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        app.buttons["Dark"].tap()
        XCTAssertTrue((appearance.label + (appearance.value as? String ?? "")).contains("Dark"))
        openDevice(in: app)

        let permission = app.switches["deviceControlToggle"]
        let method = app.buttons["deviceConnectionMethodPicker"]
        XCTAssertEqual(app.staticTexts["deviceConnectionStatus"].label, "Not paired")
        XCTAssertTrue(permission.isHittable)
        XCTAssertLessThan(permission.frame.maxY, method.frame.minY)
        XCTAssertFalse(app.buttons["devicePairingSetupButton"].exists)
        XCTAssertFalse(app.buttons["preparePairingButton"].exists)
        XCTAssertTrue(app.buttons["importPairingIdentityButton"].exists)
        let viewport = "\(Int(app.frame.width))x\(Int(app.frame.height))"
        saveScreenshot(app, name: "Device-English-Dark-Unpaired-\(viewport)")

        let startPairing = app.buttons["startPairingButton"]
        XCTAssertTrue(startPairing.waitForExistence(timeout: 5))
        revealDeviceElement(startPairing, in: app)
        XCTAssertEqual(startPairing.label, "Start pairing")
        XCTAssertTrue(startPairing.isEnabled)
        XCTAssertTrue(app.navigationBars["Device"].exists, "System pairing is directly available on the device page.")
        XCTAssertTrue(app.buttons["importPairingIdentityButton"].exists)
        XCTAssertFalse(app.buttons["copyComputerPairingCommandButton"].exists)
        XCTAssertFalse(app.buttons["disconnectDeviceButton"].exists)
        XCTAssertFalse(app.staticTexts["pairingCode"].exists)
        saveScreenshot(app, name: "Device-English-Dark-System-Pairing-\(viewport)")
        #endif
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor
    private func revealDeviceElement(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable && element.frame.maxY < app.frame.maxY - 24 { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertLessThan(element.frame.maxY, app.frame.maxY - 24)
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
