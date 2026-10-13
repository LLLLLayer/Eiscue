import XCTest

final class ModelProfilesUITests: XCTestCase {
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

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
}
