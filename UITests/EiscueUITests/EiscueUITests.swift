import XCTest

final class EiscueUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if reset { app.launchArguments.append("--reset-state") }
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openModelSettings(in app: XCUIApplication) {
        openSettings(in: app)
        app.buttons["modelSettingsButton"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editModelProfile_")).firstMatch
        if edit.waitForExistence(timeout: 2) { edit.tap() }
        XCTAssertTrue(app.textFields["modelBaseURL"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let clearIdentifiers = ["modelBaseURL": "clearModelBaseURLButton", "modelIdentifier": "clearModelIdentifierButton"]
        if let identifier = clearIdentifiers[field.identifier], app.buttons[identifier].isHittable {
            app.buttons[identifier].tap()
        } else if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            // A simulated Command-A can leave only part of a URL selected.
            // Use the visible edit menu and verify the replacement itself.
            field.press(forDuration: 1)
            let selectAll = app.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", ["全选", "Select All"])
            ).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue)
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            // Scroll the presented form, above the keyboard's password bar.
            let forms = app.collectionViews.allElementsBoundByIndex
            let form = forms.last(where: \.isHittable) ?? forms.last
            let viewport = form?.frame ?? app.frame
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : viewport.maxY
            let bottom = min(viewport.maxY - 24, keyboardTop - (app.keyboards.firstMatch.exists ? 100 : 24))
            let top = max(viewport.minY + 24, app.frame.minY + 140)
            guard bottom > top else { break }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: viewport.maxX - 18, dy: bottom))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: viewport.maxX - 18, dy: top)))
        }
        XCTAssertTrue(element.isHittable)
    }

    /// These cases launch with reset state. Assert the actual default instead
    /// of selecting it and hiding a default-route regression.
    @MainActor
    private func assertInAppConnection(in app: XCUIApplication) {
        let picker = app.buttons["deviceConnectionMethodPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "App 内连接")
    }

    @MainActor
    func testControlBackendChoicesFollowSystemAndPersist() {
        var app = launch()
        openDevice(in: app)
        let usesCoreDevice = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        let picker = app.buttons["deviceControlBackendPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, usesCoreDevice ? "自动 · DisplayService" : "自动 · XCTest")
        picker.tap()
        let coreDevice = app.buttons["deviceControlBackendChoice_coreDevice"]
        let xcTest = app.buttons["deviceControlBackendChoice_xcTest"]
        XCTAssertTrue(coreDevice.waitForExistence(timeout: 5))
        XCTAssertEqual(coreDevice.isEnabled, usesCoreDevice)
        XCTAssertTrue(xcTest.isEnabled)
        if !usesCoreDevice { XCTAssertTrue(app.staticTexts["需要 iOS 27 或更新版本。"].exists) }
        xcTest.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "XCTest")

        app.terminate()
        app = launch(reset: false)
        openDevice(in: app)
        let restored = app.buttons["deviceControlBackendPicker"]
        XCTAssertEqual(restored.value as? String, "XCTest")
        restored.tap()
        if usesCoreDevice {
            app.buttons["deviceControlBackendChoice_coreDevice"].tap()
            XCTAssertEqual(restored.value as? String, "DisplayService")
            restored.tap()
        }
        app.buttons["deviceControlBackendChoice_automatic"].tap()
        XCTAssertEqual(restored.value as? String, usesCoreDevice ? "自动 · DisplayService" : "自动 · XCTest")
    }

    @MainActor
    func testControlBackendIsSharedByNetworkRoutesAndHiddenForBluetooth() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openDevice(in: app)
        let backend = app.buttons["deviceControlBackendPicker"]
        XCTAssertEqual(backend.label, "Control method")
        backend.tap()
        app.buttons["deviceControlBackendChoice_xcTest"].tap()
        for route in ["usbBoard", "bluetoothBoard", "localVPN"] {
            app.buttons["deviceConnectionMethodPicker"].tap()
            app.buttons["deviceConnectionChoice_\(route)"].tap()
            if route == "bluetoothBoard" {
                XCTAssertTrue(backend.waitForNonExistence(timeout: 5))
            } else {
                XCTAssertTrue(backend.waitForExistence(timeout: 5))
                XCTAssertEqual(backend.value as? String, "XCTest")
            }
        }
        XCTAssertFalse(app.buttons["disconnectDeviceButton"].exists, "Choosing a backend must not start a connection.")
    }

    @MainActor
    func testBoardStopNoticeStaysVisibleAcrossNavigationAndScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "--board-stop-notice-fixture",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let title = app.descendants(matching: .any).matching(identifier: "boardHardwareStopTitle").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(title.isHittable)
        openDevice(in: app)
        XCTAssertTrue(title.isHittable)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(title.isHittable, "Stopping must remain visible even when the setup page is scrolled.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1.5")).firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Board stop notice"; image.lifetime = .keepAlways; add(image)
    }

    @MainActor
    func testAdvancedOptionsAreHiddenUntilRequested() throws {
        let app = launch()
        openModelSettings(in: app)
        let outputLimit = app.textFields["maxOutputTokensInput"]
        XCTAssertFalse(outputLimit.exists)
        let advanced = app.descendants(matching: .any).matching(identifier: "modelAdvancedOptions").firstMatch
        reveal(advanced, in: app)
        advanced.tap()
        // Form rows appear lazily on scroll.
        reveal(outputLimit, in: app)
        XCTAssertTrue(outputLimit.exists)
        app.navigationBars.buttons["取消"].tap()
        openDevice(in: app)
        assertInAppConnection(in: app)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        XCTAssertFalse(app.buttons["检查点击和输入"].exists)
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        let copyCommand = app.buttons["copyComputerPairingCommandButton"]
        reveal(copyCommand, in: app)
        XCTAssertTrue(copyCommand.isEnabled)
        XCTAssertTrue(app.buttons["importPairingIdentityButton"].exists)
        // Verification tools appear only once device control is ready.
        XCTAssertFalse(app.buttons["检查点击和输入"].exists)
    }

    @MainActor
    func testUnconfiguredSendOpensModelSettingsWithoutCreatingConversation() throws {
        let app = launch()
        XCTAssertFalse(app.buttons["sendMessageButton"].isEnabled)
        let field = app.textFields["messageInput"].exists
            ? app.textFields["messageInput"] : app.textViews["messageInput"]
        field.tap()
        field.typeText("Help me plan a morning")
        app.buttons["sendMessageButton"].tap()
        XCTAssertTrue(app.textFields["modelBaseURL"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveModelSettingsButton"].isEnabled)
        app.navigationBars.buttons["取消"].tap()

        openSidebar(in: app)
        XCTAssertTrue(app.staticTexts["还没有对话"].waitForExistence(timeout: 5))
        closeSidebar(in: app)
        XCTAssertTrue(field.value as? String == "Help me plan a morning")
    }

    @MainActor
    func testModelConfigurationValidatesHTTPSAndDoesNotPrefillSavedKey() throws {
        var app = launch()
        openModelSettings(in: app)
        replace(app.textFields["modelBaseURL"], with: "http://example.invalid/v1", in: app)
        replace(app.textFields["modelIdentifier"], with: "ui-test-model", in: app)
        let key = "eiscue-ui-test-placeholder"
        let secureField = app.secureTextFields["modelAPIKey"]
        reveal(secureField, in: app)
        secureField.tap()
        secureField.typeText(key)
        app.buttons["saveModelSettingsButton"].tap()
        XCTAssertTrue(app.alerts["无法保存"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["请使用 HTTPS 地址，不含账号信息、查询参数或 # 片段。"].exists)
        app.alerts.buttons["好"].tap()

        replace(app.textFields["modelBaseURL"], with: "https://example.invalid/v1", in: app)
        app.buttons["saveModelSettingsButton"].tap()
        XCTAssertTrue(app.buttons["addModelProfileButton"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["modelSettingsButton"].waitForExistence(timeout: 5))
        app.terminate()

        app = launch(reset: false)
        openModelSettings(in: app)
        XCTAssertEqual(app.textFields["modelBaseURL"].value as? String, "https://example.invalid/v1")
        XCTAssertEqual(app.textFields["modelIdentifier"].value as? String, "ui-test-model")
        XCTAssertTrue(app.staticTexts["已保存 API Key"].exists)
        let savedKeyField = app.secureTextFields["modelAPIKey"]
        XCTAssertFalse(savedKeyField.exists, "Saved credentials must not appear in an editable field.")
        XCTAssertFalse(app.staticTexts[key].exists)
        reveal(app.buttons["replaceAPIKeyButton"], in: app)
        app.buttons["replaceAPIKeyButton"].tap()
        reveal(savedKeyField, in: app)
        XCTAssertTrue((savedKeyField.value as? String ?? "").isEmpty || savedKeyField.value as? String == savedKeyField.placeholderValue)
        XCTAssertFalse(app.buttons["saveModelSettingsButton"].isEnabled)
        app.buttons["removeAPIKeyButton"].tap()
        app.buttons["删除密钥"].tap()
        XCTAssertTrue(app.staticTexts["已保存 API Key"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveModelSettingsButton"].isEnabled)
        app.navigationBars.buttons["取消"].tap()
        app.navigationBars.buttons["完成"].tap()
    }

    @MainActor
    func testAppearancePersistsAcrossLaunches() throws {
        var app = launch()
        openSettings(in: app)
        let picker = app.buttons["appearancePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["深色"].tap()
        XCTAssertTrue((picker.label + (picker.value as? String ?? "")).contains("深色"))
        app.terminate()

        app = launch(reset: false)
        openSettings(in: app)
        let restored = app.buttons["appearancePicker"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue((restored.label + (restored.value as? String ?? "")).contains("深色"))
        restored.tap()
        app.buttons["跟随系统"].tap()
    }

    @MainActor
    func testBuiltInSkillCanBePreviewedAndSelected() throws {
        let app = launch()
        openSettings(in: app)
        app.buttons["skillsNavigationLink"].tap()
        let skill = app.buttons["skillRow_ios-navigation"]
        XCTAssertTrue(skill.waitForExistence(timeout: 5))
        skill.tap()
        XCTAssertTrue(app.staticTexts["skillContentPreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["skillContentPreview"].label.contains("Observe the current screen before deciding what to do next."))
        let source = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "内置", "内置")
        ).firstMatch
        XCTAssertTrue(source.exists)
        XCTAssertFalse(app.buttons["删除技能"].exists)
        let selection = app.buttons["selectSkillButton"]
        selection.tap()
        XCTAssertTrue(selection.label.contains("取消使用"))
        selection.tap()
        XCTAssertTrue(selection.label.contains("使用技能"))
    }

    @MainActor
    func testUnpairedLocalConnectionShowsPreparationBeforeStartingVPN() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This case checks setup gating on a simulator and must not start a real VPN.")
        #else
        let app = launch()
        openDevice(in: app)
        assertInAppConnection(in: app)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        XCTAssertFalse(app.buttons["connectDeviceButton"].exists)
        XCTAssertFalse(app.staticTexts["localTunnelStatus"].exists)
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            XCTAssertFalse(app.buttons["startPairingButton"].exists)
            let copyCommand = app.buttons["copyComputerPairingCommandButton"]
            reveal(copyCommand, in: app)
            XCTAssertTrue(copyCommand.isEnabled)
            XCTAssertTrue(app.buttons["importPairingIdentityButton"].exists)
        }
        XCTAssertFalse(app.staticTexts["pairingCode"].exists)
        #endif
    }

    @MainActor
    func testIOS26ShowsUSBImportInsteadOfSystemPairing() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This case checks the iOS 26 setup guide on a simulator.")
        #else
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 else {
            throw XCTSkip("This case checks the iOS 26 USB setup path.")
        }
        let app = launch()
        openDevice(in: app)
        assertInAppConnection(in: app)
        let guidance = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "USB", "开发者模式")).firstMatch
        reveal(guidance, in: app)
        XCTAssertTrue(guidance.label.contains("USB"))
        XCTAssertFalse(app.buttons["startPairingButton"].exists)
        let importButton = app.buttons["importPairingIdentityButton"]
        reveal(importButton, in: app)
        XCTAssertTrue(importButton.isEnabled)
        XCTAssertEqual(importButton.label, "选择已有配对文件")
        XCTAssertFalse(app.buttons["connectDeviceButton"].exists)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        XCTAssertFalse(app.buttons["deviceConnectionHelpButton"].exists)
        XCTAssertTrue(app.buttons["copyComputerPairingCommandButton"].exists)
        XCTAssertFalse(app.staticTexts["pairingCode"].exists)
        #endif
    }

    @MainActor
    func testDeviceControlProbeRespondsToTapInputAndScroll() throws {
        let app = launch()
        openDevice(in: app)
        assertInAppConnection(in: app)
        let openProbe = app.buttons["deviceProbeButton"]
        guard openProbe.waitForExistence(timeout: 2) else {
            throw XCTSkip("The probe entry is shown only when device control is ready, which a simulator cannot reach.")
        }
        reveal(openProbe, in: app)
        openProbe.tap()
        XCTAssertTrue(app.staticTexts["probeCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["probeCount"].label, "计数：0")
        app.buttons["probeIncrement"].tap()
        app.buttons["probeIncrement"].tap()
        XCTAssertEqual(app.staticTexts["probeCount"].label, "计数：2")
        app.buttons["归零"].tap()
        XCTAssertEqual(app.staticTexts["probeCount"].label, "计数：0")
        app.textFields["probeInput"].tap()
        app.textFields["probeInput"].typeText("Eiscue UI 26")
        XCTAssertEqual(app.staticTexts["probeEcho"].label, "Eiscue UI 26")
        let lastRow = app.staticTexts["验证行 20"]
        reveal(lastRow, in: app)
        XCTAssertTrue(lastRow.isHittable)
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["设备"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRunHistoryIsEmptyBeforeFirstRun() throws {
        let app = launch()
        openSettings(in: app)
        app.buttons["runHistoryNavigationLink"].tap()
        XCTAssertTrue(app.staticTexts["还没有任务记录"].waitForExistence(timeout: 5))
    }
}
