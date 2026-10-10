import XCTest

/// Run Scripts/test-model-server.py first. The runtime is the real Pi engine;
/// only the model HTTP endpoint is replaced by a deterministic loopback server.
final class AgentIntegrationUITests: XCTestCase {
    @MainActor private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if reset { app.launchArguments.append("--reset-state") }
        app.launchEnvironment["EISCUE_TEST_MODEL_URL"] = "http://127.0.0.1:18765/v1"
        app.launch()
        return app
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap(); input.typeText(text)
        app.buttons["sendMessageButton"].tap()
    }

    @MainActor func testRealRuntimeStreamsAndPersistsAcrossLaunches() throws {
        var app = launch()
        send("Plan a calm morning", in: app)
        XCTAssertTrue(app.staticTexts["Fixture response: Plan a calm morning"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout: 5))
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(app.staticTexts["Fixture response: Plan a calm morning"].waitForExistence(timeout: 10))
        send("Next step", in: app)
        XCTAssertTrue(app.staticTexts["Fixture response: Next step"].waitForExistence(timeout: 20))
        app.buttons["newConversationButton"].tap()
        app.buttons["historyButton"].tap()
        let row = app.buttons.containing(.staticText, identifier: "Plan a calm morning").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft(); app.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["还没有会话"].waitForExistence(timeout: 5))
    }

    @MainActor func testStopDoesNotAutomaticallyResumeOnLaunch() throws {
        var app = launch()
        send("slow fixture", in: app)
        XCTAssertTrue(app.buttons["stopRunButton"].waitForExistence(timeout: 15))
        app.buttons["stopRunButton"].tap()
        XCTAssertTrue(app.buttons["resumeRunButton"].waitForExistence(timeout: 10))
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(app.buttons["resumeRunButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["stopRunButton"].exists)
        app.buttons["结束任务"].tap()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
    }
}
