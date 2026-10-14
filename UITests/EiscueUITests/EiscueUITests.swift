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
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func expandDeviceOptions(in app: XCUIApplication) {
        let help = app.buttons["deviceConnectionHelpButton"]
        reveal(help, in: app)
        help.tap()
    }

    /// New installs default to the Bluetooth board, whose page has no tunnel,
    /// pairing or advanced options. Choose the in-app connection explicitly.
    @MainActor
    private func selectInAppConnection(in app: XCUIApplication) {
        let picker = app.buttons["deviceConnectionMethodPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let option = app.buttons["deviceConnectionChoice_localVPN"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(app.buttons["deviceConnectionHelpButton"].waitForExistence(timeout: 5))
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
        selectInAppConnection(in: app)
        XCTAssertFalse(app.buttons["startLocalTunnelButton"].exists)
        XCTAssertFalse(app.buttons["检查点击和输入"].exists)
        expandDeviceOptions(in: app)
        XCTAssertTrue(app.buttons["startLocalTunnelButton"].exists)
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
        XCTAssertTrue(app.staticTexts["skillContentPreview"].label.contains("先观察当前屏幕"))
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
    func testEmbeddedLocalConnectionRejectsSimulatorWithoutExternalApp() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This case checks the simulator-only rejection and must not start a real VPN.")
        #else
        let app = launch()
        openDevice(in: app)
        selectInAppConnection(in: app)
        expandDeviceOptions(in: app)
        let start = app.buttons["startLocalTunnelButton"]
        reveal(start, in: app)
        XCTAssertTrue(app.staticTexts["localTunnelStatus"].exists)
        start.tap()
        let alert = app.alerts["暂时无法完成"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "模拟器")).firstMatch.exists)
        alert.buttons["知道了"].tap()
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            XCTAssertFalse(app.buttons["startPairingButton"].exists)
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
        selectInAppConnection(in: app)
        let guidance = app.staticTexts["usbPairingGuidance"]
        reveal(guidance, in: app)
        XCTAssertTrue(guidance.label.contains("USB"))
        XCTAssertFalse(app.buttons["startPairingButton"].exists)
        let importButton = app.buttons["importPairingIdentityButton"]
        reveal(importButton, in: app)
        XCTAssertTrue(importButton.isEnabled)
        XCTAssertEqual(importButton.label, "导入配对文件")
        XCTAssertFalse(app.buttons["connectDeviceButton"].exists)
        XCTAssertFalse(app.staticTexts["pairingCode"].exists)
        #endif
    }

    @MainActor
    func testDeviceControlProbeRespondsToTapInputAndScroll() throws {
        let app = launch()
        openDevice(in: app)
        selectInAppConnection(in: app)
        let openProbe = app.buttons["检查点击和输入"]
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
