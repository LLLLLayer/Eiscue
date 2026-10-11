import XCTest

/// Start Scripts/test-model-server.py before running the sticker integration test.
/// These tests never request microphone, camera, or photo-library permission.
final class RichComposerUITests: XCTestCase {
    @MainActor private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-state") }
        app.launchEnvironment["EISCUE_TEST_MODEL_URL"] = "http://127.0.0.1:18765/v1"
        app.launch()
        XCTAssertTrue(app.buttons["composerAddButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor func testAddMenuControlsDeviceAccessWithoutSendingDraft() throws {
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
        for title in ["Photos", "Camera", "Files"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3))
        }
        let deviceToggle = app.descendants(matching: .any)["deviceControlToggle"].firstMatch
        XCTAssertTrue(deviceToggle.waitForExistence(timeout: 3))
        deviceToggle.tap()
        XCTAssertTrue(app.staticTexts["Device control on"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["deviceControlEnabled"].firstMatch.exists)

        app.buttons["composerAddButton"].tap()
        XCTAssertTrue(deviceToggle.waitForExistence(timeout: 3))
        deviceToggle.tap()
        let controlOff = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Device control on"])
        XCTAssertEqual(XCTWaiter.wait(for: [controlOff], timeout: 3), .completed)

        app.buttons["deviceNavigationLink"].tap()
        XCTAssertTrue(app.navigationBars["Device"].waitForExistence(timeout: 5))
        returnToAssistant(in: app)
        XCTAssertEqual(messageInput(in: app).value as? String, "Keep this as a draft")
        XCTAssertFalse(app.descendants(matching: .any)["messageBubble"].exists)
        XCTAssertFalse(app.buttons["stopRunButton"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["speechPreview"].exists)
    }

    @MainActor func testAssistantStickerStreamsAndSurvivesRelaunch() throws {
        var app = launch()
        let input = messageInput(in: app)
        input.tap()
        input.typeText("sticker fixture")
        app.buttons["sendMessageButton"].tap()

        XCTAssertTrue(app.images["assistantSticker-wave"].firstMatch.waitForExistence(timeout: 20))
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
        assertStickerReply(in: app)
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(app.images["assistantSticker-wave"].firstMatch.waitForExistence(timeout: 10))
        assertStickerReply(in: app)
        XCTAssertFalse(app.buttons["stopRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
    }

    @MainActor private func messageInput(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        return input
    }

    @MainActor private func assertStickerReply(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hello")).firstMatch.exists,
                      file: file, line: line)
        XCTAssertEqual(app.images.matching(identifier: "assistantSticker-wave").count, 1, file: file, line: line)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "[[eiscue:wave]]")).firstMatch.exists,
                       file: file, line: line)
    }
}
