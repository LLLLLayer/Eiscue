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
        app.launchArguments = ["--skip-onboarding", "--bluetooth-setup-check", "--bluetooth-connect-once"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["bluetoothInputRoutePicker"].waitForExistence(timeout: 15))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Board setup (UI inspection only)"; image.lifetime = .keepAlways; add(image)
    }

    @MainActor
    func testConnectBluetoothCompanion() {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding", "--bluetooth-setup-check"]
        app.launch()
        connectBluetoothCompanion(in: app)
    }

    @MainActor
    func testAttachAndConnectBluetoothCompanion() {
        let app = XCUIApplication()
        guard app.state != .notRunning else { XCTFail("Open the real board setup first."); return }
        app.activate()
        connectBluetoothCompanion(in: app)
    }

    @MainActor
    private func connectBluetoothCompanion(in app: XCUIApplication) {
        let pairing = addUIInterruptionMonitor(withDescription: "Eiscue board pairing") { alert in
            guard alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Eiscue BLE")).firstMatch.exists else { return false }
            let pair = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Pair", "配对"])).firstMatch
            guard pair.exists else { return false }
            pair.tap(); return true
        }
        defer { removeUIInterruptionMonitor(pairing) }
        let route = app.segmentedControls["bluetoothInputRoutePicker"]
        XCTAssertTrue(route.waitForExistence(timeout: 15))
        route.buttons.matching(NSPredicate(format: "label IN %@", ["Bluetooth input", "蓝牙输入"])).firstMatch.tap()
        let connect = app.buttons["bluetoothConnectButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        let companion = app.descendants(matching: .any).matching(identifier: "boardCompanionHint").firstMatch
        // Drive interruption handling while iOS asks to pair. The navigation
        // title is inert; no calibration/input target is touched by the test.
        for _ in 0..<10 {
            if companion.waitForExistence(timeout: 1) { break }
            app.navigationBars.firstMatch.tap()
        }
        XCTAssertTrue(companion.waitForExistence(timeout: 90),
            "The C3 screen firmware must expose its optional status channel.")
    }

    @MainActor
    func testDisconnectBluetoothBoard() {
        let app = XCUIApplication()
        guard app.state != .notRunning else { XCTFail("Open the connected board setup first."); return }
        app.activate()
        let button = app.buttons["bluetoothDisconnectButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled)
        button.tap()
        let connect = app.buttons["bluetoothConnectButton"]
        let disconnected = NSPredicate(format: "exists == YES AND enabled == YES")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: disconnected, object: connect)], timeout: 15), .completed)
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
        let passed = ["Device control is ready", "设备操作已就绪"]
        let finished = NSPredicate(format: "label IN %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                                   passed, "Check incomplete.", "检查未完成")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: status)], timeout: 40), .completed)
        XCTAssertTrue(passed.contains(status.label), "The board input check did not pass.")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Board observed input result"; image.lifetime = .keepAlways; add(image)
        app.buttons["bluetoothValidationCloseButton"].tap()
    }
}

/// Explicit real-device navigation only; reaching authorization is not device
/// control acceptance. System VPN approval and passcodes remain user actions.
final class SystemPairingPreparationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("System pairing preparation requires a physical iPhone.")
        #else
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_DEVICE_TEST"] == "1" else {
            throw XCTSkip("Run explicitly with TEST_RUNNER_EISCUE_REAL_DEVICE_TEST=1.")
        }
        #endif
    }

    @MainActor
    func testPrepareSystemPairing() async throws {
        let app = XCUIApplication()
        // Use the real persisted app state; never reset, import an identity or
        // supply an isolated UI-testing fixture or override the user's language.
        app.launchArguments = []
        if ProcessInfo.processInfo.environment["EISCUE_WAIT_FOR_SYSTEM_PAIRING"] == "1" {
            app.launchArguments.append("--pairing-diagnostics")
        }
        let pair = app.buttons["startPairingButton"]
        if ProcessInfo.processInfo.environment["EISCUE_ATTACH_EXISTING_PAIRING"] == "1" {
            XCTAssertEqual(app.state, .runningForeground, "Launch the standalone pairing check first.")
            XCTAssertTrue(app.buttons["deviceConnectionMethodPicker"].waitForExistence(timeout: 5))
        } else {
            app.launch()
            let next = app.buttons["onboardingContinueButton"]
            if next.waitForExistence(timeout: 5) {
                next.tap()
                XCTAssertTrue(app.buttons["onboardingConfigureModel"].waitForExistence(timeout: 5))
                next.tap() // Continue without configuring or calling a model.
                XCTAssertTrue(app.buttons["deviceConnectionMethodPicker"].waitForExistence(timeout: 5))
                next.tap()
            }
            XCTAssertTrue(app.buttons["deviceNavigationLink"].waitForExistence(timeout: 10))
            openDevice(in: app)
            let route = app.buttons["deviceConnectionMethodPicker"]
            XCTAssertTrue(route.waitForExistence(timeout: 5))
            XCTAssertTrue(["In app", "App 内连接"].contains(route.value as? String ?? ""),
                          "Do not change an existing connection choice automatically.")
            if app.buttons["connectDeviceButton"].waitForExistence(timeout: 2) {
                throw XCTSkip("An identity already exists; this run did not perform system pairing.")
            }
            XCTAssertTrue(pair.waitForExistence(timeout: 5))
            XCTAssertTrue(pair.isHittable && pair.isEnabled)
            pair.tap()
        }

        if ProcessInfo.processInfo.environment["EISCUE_OPEN_PAIRING_SETTINGS"] == "1" {
            let ready = NSPredicate(format: "label IN %@", [
                "In Settings → Privacy & Security → Developer Mode, select Eiscue, then tap Pair. Return to Eiscue for the code and enter it in Settings. Return to Eiscue when done.",
                "前往「设置 → 隐私与安全性 → 开发者模式」，选择 Eiscue，再点“配对”。返回 App 查看验证码，回到系统输入；完成后返回 App。"
            ])
            let publication = XCTNSPredicateExpectation(predicate: ready, object: app.staticTexts["deviceConnectionMessage"])
            guard await XCTWaiter.fulfillment(of: [publication], timeout: 15) == .completed else {
                XCTFail("Pairing publication did not become ready. Leave Settings untouched.")
                return
            }
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            // A stale Developer Mode discovery page can stop responding after
            // repeated pairing attempts. Relaunch only Settings, preserving App.
            settings.terminate()
            settings.launch()
            if !settings.navigationBars["Developer Mode"].waitForExistence(timeout: 3) {
                for _ in 0..<5 {
                    if settings.navigationBars["Settings"].exists
                        || settings.navigationBars["Privacy & Security"].exists { break }
                    let back = settings.navigationBars.firstMatch.buttons.firstMatch
                    XCTAssertTrue(back.exists)
                    back.tap()
                }
                let privacy = settings.cells.containing(.staticText, identifier: "Privacy & Security").firstMatch
                for _ in 0..<6 where !privacy.exists { settings.swipeUp() }
                if privacy.exists { privacy.tap() }
                let mode = settings.cells.containing(.staticText, identifier: "Developer Mode").firstMatch
                for _ in 0..<6 where !mode.exists { settings.swipeUp() }
                XCTAssertTrue(mode.waitForExistence(timeout: 5))
                mode.tap()
            }
            XCTAssertTrue(settings.navigationBars["Developer Mode"].waitForExistence(timeout: 5))
            let peers = settings.cells.containing(.staticText, identifier: "Pair with Eiscue")
            XCTAssertTrue(peers.firstMatch.waitForExistence(timeout: 20))
            XCTAssertEqual(peers.count, 1, "Do not choose an ambiguous or absent pairing target.")
            peers.firstMatch.tap()
            // Selecting the discovered host only opens a second confirmation.
            // Entering the phone passcode or pairing PIN remains a user action.
            let confirmation = settings.alerts.buttons["Pair"]
            guard confirmation.waitForExistence(timeout: 10) else {
                XCTFail("System pairing confirmation did not appear; leave authorization untouched.")
                return
            }
            confirmation.tap()
            try await Task.sleep(for: .seconds(2))
            app.activate() // Leave system passwords and pairing-code entry to the user.
        }
        if ProcessInfo.processInfo.environment["EISCUE_WAIT_FOR_SYSTEM_PAIRING"] == "1" {
            // Keep the test alive while the user authorizes pairing in Settings.
            // XCTest may terminate the app when a test ends. Saved pending
            // credentials alone are not evidence of a completed pairing.
            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            while ContinuousClock.now < deadline {
                if app.state == .runningForeground {
                    let message = app.staticTexts["deviceConnectionMessage"]
                    if app.buttons["connectDeviceButton"].exists,
                       message.exists, ["Paired. You can now connect.", "配对完成，可以连接了。"].contains(message.label) { return }
                    if pair.exists, pair.isEnabled, message.exists {
                        XCTFail("Pairing stopped before completion. Inspect the device's connection message.")
                        return
                    }
                }
                try await Task.sleep(for: .seconds(1))
            }
            XCTFail("System pairing did not complete within 300 seconds. System authorization was left to the user.")
            return
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let vpnText = NSPredicate(format: "label CONTAINS[c] %@", "VPN")
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if springboard.alerts.containing(vpnText).firstMatch.exists
                || app.alerts.containing(vpnText).firstMatch.exists
                || app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Pairing", "正在配对"])).firstMatch.exists {
                return // System authorization is untouched; app lifetime is runner-managed.
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Pairing did not reach the system VPN authorization or pairing state. No system authorization was accepted.")
    }
}
