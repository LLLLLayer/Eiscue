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
        openSidebar(in: app)
        app.buttons["newConversationButton"].tap()
        openSidebar(in: app)
        let row = row(titled: "Plan a calm morning", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        app.buttons["deleteConversationButton"].tap()
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

    @MainActor func testSidebarOrderPinAndDeletePersistAcrossLaunches() throws {
        var app = launch()
        for (index, title) in ["First conversation", "Second conversation", "Third conversation"].enumerated() {
            if index > 0 {
                openSidebar(in: app)
                app.buttons["newConversationButton"].tap()
            }
            send(title, in: app)
            XCTAssertTrue(app.staticTexts["Fixture response: \(title)"].waitForExistence(timeout: 20))
            let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
            XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed)
        }
        openSidebar(in: app)
        assertOrder(["Third conversation", "Second conversation", "First conversation"], in: app)
        row(titled: "First conversation", in: app).press(forDuration: 1)
        app.buttons["moveConversationUpButton"].tap()
        assertOrder(["Third conversation", "First conversation", "Second conversation"], in: app)
        row(titled: "Second conversation", in: app).press(forDuration: 1)
        app.buttons["pinConversationButton"].tap()
        assertOrder(["Second conversation", "Third conversation", "First conversation"], in: app)
        XCTAssertEqual(row(titled: "Second conversation", in: app).value as? String, "已置顶")
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(app.buttons["historyButton"].waitForExistence(timeout: 10))
        openSidebar(in: app)
        assertOrder(["Second conversation", "Third conversation", "First conversation"], in: app)
        XCTAssertEqual(row(titled: "Second conversation", in: app).value as? String, "已置顶")
        row(titled: "Third conversation", in: app).press(forDuration: 1)
        app.buttons["moveConversationDownButton"].tap()
        assertOrder(["Second conversation", "First conversation", "Third conversation"], in: app)
        row(titled: "First conversation", in: app).press(forDuration: 1)
        app.buttons["deleteConversationButton"].tap()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row(titled: "First conversation", in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 10), .completed)
        assertOrder(["Second conversation", "Third conversation"], in: app)
    }

    @MainActor private func row(titled title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "conversationRow_", title)).firstMatch
    }

    @MainActor private func assertOrder(_ titles: [String], in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let rows = titles.map { row(titled: $0, in: app) }
        for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line) }
        for (above, below) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThan(above.frame.midY, below.frame.midY, file: file, line: line)
        }
    }
}
