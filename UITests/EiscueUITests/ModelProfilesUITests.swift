import XCTest

final class ModelProfilesUITests: XCTestCase {
    @MainActor func testAdvancedLimitsAcceptTypedValuesAndRejectInvalidDrafts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openSettings(in: app)
        app.buttons["modelSettingsButton"].tap()
        saveNewProfile("Daily", modelID: "model-one", key: "ui-key-one", in: app)
        XCTAssertFalse(app.staticTexts["Tap to switch. You can also switch from the menu at the top of a conversation."].exists)
        app.buttons["Edit Daily"].tap()
        expandAdvanced(in: app)

        replaceLimit("maxOutputTokensInput", with: "32769", in: app)
        app.buttons["saveModelSettingsButton"].tap()
        XCTAssertTrue(app.staticTexts["maxOutputTokensInputError"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["maxOutputTokensInput"].value as? String, "32769", "Invalid drafts must not be clamped or silently saved.")
        replaceLimit("maxOutputTokensInput", with: "5001", in: app)
        replaceLimit("maxToolCallsInput", with: "", in: app)
        app.buttons["saveModelSettingsButton"].tap()
        XCTAssertTrue(app.staticTexts["maxToolCallsInputError"].waitForExistence(timeout: 5))
        replaceLimit("maxToolCallsInput", with: "37", in: app)
        replaceLimit("taskTimeoutInput", with: "0", in: app)
        app.buttons["saveModelSettingsButton"].tap()
        XCTAssertTrue(app.staticTexts["taskTimeoutInputError"].waitForExistence(timeout: 5))
        replaceLimit("taskTimeoutInput", with: "91", in: app)
        app.buttons["modelLimitsKeyboardDoneButton"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Use HTTPS. Screen tasks need a model that accepts images."].exists)
        app.buttons["saveModelSettingsButton"].tap()
        XCTAssertTrue(profile("Daily", in: app).waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-state" }
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openSettings(in: app)
        app.buttons["modelSettingsButton"].tap()
        app.buttons["Edit Daily"].tap()
        XCTAssertFalse(app.secureTextFields["modelAPIKey"].exists, "Editing limits must preserve the saved API key.")
        expandAdvanced(in: app)
        for (identifier, value) in [("maxOutputTokensInput", "5001"), ("maxToolCallsInput", "37"), ("taskTimeoutInput", "91")] {
            let field = app.textFields[identifier]
            reveal(field, in: app)
            XCTAssertEqual(field.value as? String, value)
        }
    }

    @MainActor func testNamedModelsSwitchFromChatAndPersistIndependently() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openSettings(in: app)
        app.buttons["modelSettingsButton"].tap()
        saveNewProfile("Everyday", modelID: "model-one", key: "ui-key-one", in: app)
        app.buttons["addModelProfileButton"].tap()
        saveNewProfile("Writing", modelID: "model-two", key: "ui-key-two", in: app)
        XCTAssertEqual(profile("Writing", in: app).value as? String, "Selected")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Saved model profiles"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars.buttons["Done"].tap()
        returnToAssistant(in: app)
        app.buttons["conversationMenuButton"].tap()
        let quickSwitch = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "switchModelProfile_", "Everyday")).firstMatch
        XCTAssertTrue(quickSwitch.waitForExistence(timeout: 5))
        quickSwitch.tap()

        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-state" }
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openSettings(in: app)
        app.buttons["modelSettingsButton"].tap()
        XCTAssertEqual(profile("Everyday", in: app).value as? String, "Selected")
        XCTAssertNotEqual(profile("Writing", in: app).value as? String, "Selected")
        app.buttons["Edit Writing"].tap()
        XCTAssertEqual(app.textFields["modelIdentifier"].value as? String, "model-two")
        XCTAssertFalse(app.secureTextFields["modelAPIKey"].exists)
        let editorScreenshot = XCTAttachment(screenshot: app.screenshot())
        editorScreenshot.name = "Saved model editor"; editorScreenshot.lifetime = .keepAlways; add(editorScreenshot)
        let name = app.textFields["modelProfileName"]
        name.tap()
        app.buttons["clearModelNameButton"].tap()
        name.typeText("Writing assistant")
        app.buttons["saveModelSettingsButton"].tap()
        XCTAssertTrue(profile("Writing assistant", in: app).waitForExistence(timeout: 5))
        profile("Writing assistant", in: app).press(forDuration: 1)
        app.buttons["Delete model"].firstMatch.tap()
        app.buttons.matching(identifier: "confirmDeleteModelProfileButton").firstMatch.tap()
        XCTAssertTrue(profile("Writing assistant", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(profile("Everyday", in: app).exists)
    }

    @MainActor private func saveNewProfile(_ name: String, modelID: String, key: String, in app: XCUIApplication) {
        let profileName = app.textFields["modelProfileName"]
        XCTAssertTrue(profileName.waitForExistence(timeout: 5))
        profileName.tap(); profileName.typeText(name)
        let url = app.textFields["modelBaseURL"]
        url.tap(); app.buttons["clearModelBaseURLButton"].tap(); url.typeText("https://example.invalid/v1")
        let identifier = app.textFields["modelIdentifier"]
        reveal(identifier, in: app)
        identifier.tap(); identifier.typeText(modelID)
        let credential = app.secureTextFields["modelAPIKey"]
        reveal(credential, in: app)
        credential.tap(); credential.typeText(key)
        app.buttons["saveModelSettingsButton"].tap()
        XCTAssertTrue(app.buttons["addModelProfileButton"].waitForExistence(timeout: 5))
    }

    @MainActor private func profile(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "selectModelProfile_", name)).firstMatch
    }

    @MainActor private func expandAdvanced(in app: XCUIApplication) {
        let advanced = app.descendants(matching: .any).matching(identifier: "modelAdvancedOptions").firstMatch
        reveal(advanced, in: app)
        advanced.tap()
    }

    @MainActor private func replaceLimit(_ identifier: String, with value: String, in app: XCUIApplication) {
        if app.keyboards.firstMatch.exists {
            let done = app.buttons["modelLimitsKeyboardDoneButton"]
            XCTAssertTrue(done.waitForExistence(timeout: 3))
            done.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        let field = app.textFields[identifier]
        reveal(field, in: app)
        let clear = app.buttons["clear\(identifier)Button"]
        if clear.exists, clear.isEnabled {
            if clear.isHittable { clear.tap() }
            else {
                // iOS 26's Form can report no AX hit point after inline
                // validation, although the enabled Clear button is visible.
                // Tap its observed bounds, then verify the real edit below.
                XCTAssertTrue(app.frame.contains(clear.frame))
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: clear.frame.midX, dy: clear.frame.midY)).tap()
            }
            let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let contents = field.value as? String
                return contents == "" || contents == field.placeholderValue
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 3), .completed, "Clear must remove the previous numeric value before typing.")
        }
        field.tap()
        if !value.isEmpty { field.typeText(value) }
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
}
