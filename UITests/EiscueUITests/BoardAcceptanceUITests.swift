import XCTest

/// Explicit opt-in, physical-board acceptance. The runner never generates the
/// calibration touches or text; the App validates events emitted by the board.
final class BoardAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("BLE/USB HID acceptance requires a physical iPhone and board.")
        #else
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_BOARD_TEST"] == "1" else {
            throw XCTSkip("Run explicitly with TEST_RUNNER_EISCUE_REAL_BOARD_TEST=1 after connecting the board.")
        }
        #endif
    }

    @MainActor
    func testInspectSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding", "--bluetooth-setup-check", "--bluetooth-connect-once",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["bluetoothInputRoutePicker"].waitForExistence(timeout: 15))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Board setup (UI inspection only)"; image.lifetime = .keepAlways; add(image)
    }

    @MainActor
    func testConnectBluetoothCompanion() {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding", "--bluetooth-setup-check",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let route = app.segmentedControls["bluetoothInputRoutePicker"]
        XCTAssertTrue(route.waitForExistence(timeout: 15))
        route.buttons["蓝牙输入"].tap()
        let connect = app.buttons["bluetoothConnectButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "boardCompanionHint").firstMatch.waitForExistence(timeout: 45),
            "The C3 screen firmware must expose its optional status channel.")
    }

    @MainActor
    func testVerifyObservedInput() {
        let app = XCUIApplication()
        // Preserve the user's already-confirmed screen broadcast and connection.
        guard app.state != .notRunning else { XCTFail("Open Eiscue's device page and confirm screen sharing first."); return }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        let button = app.buttons["bluetoothVerifyButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable && button.isEnabled, "Connect the board and confirm screen sharing first.")
        button.tap()
        let status = app.staticTexts["bluetoothValidationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let finished = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "设备操作已就绪", "检查未完成")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: status)], timeout: 40), .completed)
        XCTAssertEqual(status.label, "设备操作已就绪")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Board observed input result"; image.lifetime = .keepAlways; add(image)
        app.buttons["bluetoothValidationCloseButton"].tap()
    }
}
