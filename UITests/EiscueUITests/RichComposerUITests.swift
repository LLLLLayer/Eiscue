import XCTest

/// Start Scripts/test-model-server.py before running the plain-chat integration test.
/// These tests never request microphone, camera, or photo-library permission.
final class RichComposerUITests: XCTestCase {
    @MainActor private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-state") }
        app.launchEnvironment["EISCUE_TEST_MODEL_URL"] = modelFixtureURL().absoluteString
        app.launch()
        XCTAssertTrue(app.buttons["composerAddButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor func testDevicePageControlsAccessWithoutSendingDraft() throws {
        let app = launch()
        XCTAssertFalse(app.descendants(matching: .any)["taskScopePicker"].exists)
        XCTAssertTrue(app.buttons["speechInputButton"].exists)
        XCTAssertTrue(app.buttons["speechInputButton"].isEnabled)
        XCTAssertTrue(app.buttons["deviceNavigationLink"].isHittable)
        XCTAssertFalse(app.staticTexts["Device control on"].exists)

        let input = messageInput(in: app)
        input.tap()
        input.typeText("Keep this as a draft")
        app.buttons["composerAddButton"].tap()
        for title in ["Choose photos", "Take photo", "Choose files"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3))
        }
        XCTAssertFalse(app.descendants(matching: .any)["deviceControlToggle"].exists)
        // Dismiss the attachment menu without opening a system picker.
        app.navigationBars["Eiscue"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let menuClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Choose photos"])
        XCTAssertEqual(XCTWaiter.wait(for: [menuClosed], timeout: 3), .completed)
        app.buttons["deviceNavigationLink"].tap()
        XCTAssertTrue(app.navigationBars["Device"].waitForExistence(timeout: 5))
        let deviceToggle = app.switches["deviceControlToggle"]
        XCTAssertTrue(deviceToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(deviceToggle.value as? String, "1")
        deviceToggle.tap()
        XCTAssertEqual(deviceToggle.value as? String, "0")
        returnToAssistant(in: app)
        XCTAssertEqual(messageInput(in: app).value as? String, "Keep this as a draft")
        XCTAssertFalse(app.descendants(matching: .any)["messageBubble"].exists)
        XCTAssertFalse(app.buttons["stopRunButton"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["speechPreview"].exists)
        app.terminate()
        let restored = launch(reset: false)
        restored.buttons["deviceNavigationLink"].tap()
        XCTAssertEqual(restored.switches["deviceControlToggle"].value as? String, "0")
    }

    @MainActor func testPlainChatWithoutPluginsSurvivesRelaunch() throws {
        var app = launch()
        sendPlainChat("plain chat fixture", in: app)
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(app.staticTexts["Fixture response: plain chat fixture"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["stopRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        // The fixture verifies the actual model request: minimal instructions,
        // no tools, and the complete previous turn restored after relaunch.
        sendPlainChat("plain chat follow-up fixture", in: app)
    }

    @MainActor private func messageInput(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        return input
    }

    @MainActor private func sendPlainChat(_ text: String, in app: XCUIApplication,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let input = messageInput(in: app)
        input.tap()
        input.typeText(text)
        app.buttons["sendMessageButton"].tap()
        XCTAssertTrue(app.staticTexts["Fixture response: \(text)"].waitForExistence(timeout: 20),
                      file: file, line: line)
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed, file: file, line: line)
        XCTAssertEqual(app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistantSticker-")).count,
                       0, file: file, line: line)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "[[eiscue:")).firstMatch.exists,
                       file: file, line: line)
    }
}
