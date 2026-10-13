import XCTest

/// Run Scripts/test-model-server.py first. The runtime is the real Pi engine;
/// only the model HTTP endpoint is replaced by a deterministic loopback server.
final class AgentIntegrationUITests: XCTestCase {
    @MainActor private func launch(reset: Bool = true, timeline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if reset { app.launchArguments.append("--reset-state") }
        if timeline { app.launchArguments.append("--tool-timeline-fixture") }
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
        waitUntilIdle(in: app)
        XCTAssertFalse(app.staticTexts["已完成"].exists)
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

    @MainActor func testAuthenticationFailureKeepsAppAndDraftUsable() throws {
        assertServiceFailureCanRecover(prompt: "unauthorized fixture", error: "Fixture authentication failed")
    }

    @MainActor func testServerFailureKeepsAppAndDraftUsable() throws {
        assertServiceFailureCanRecover(prompt: "unavailable fixture", error: "Fixture service unavailable")
    }

    @MainActor private func assertServiceFailureCanRecover(prompt: String, error: String,
                                                          file: StaticString = #filePath, line: UInt = #line) {
        let app = launch()
        send(prompt, in: app)
        let detail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", error)).firstMatch
        guard detail.waitForExistence(timeout: 20) else {
            XCTFail("Expected a visible service error without terminating the app", file: file, line: line)
            return
        }
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                            object: app.buttons["stopRunButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed, file: file, line: line)
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertNotEqual(input.value as? String, prompt, "A submitted message stays on the transcript after a service failure.", file: file, line: line)
        XCTAssertTrue(app.staticTexts[prompt].exists, file: file, line: line)
        XCTAssertFalse(app.debugDescription.contains("local-fixture-key"),
                       "A provider error must not expose the configured credential", file: file, line: line)

        // No relaunch or direct state reset: the failed app session must still
        // allow ordinary navigation and another real model request.
        openSidebar(in: app)
        let newConversation = app.buttons["newConversationButton"]
        XCTAssertTrue(newConversation.isEnabled, file: file, line: line)
        newConversation.tap()
        send("Conversation after service failure", in: app)
        XCTAssertTrue(app.staticTexts["Fixture response: Conversation after service failure"].waitForExistence(timeout: 20),
                      file: file, line: line)
        waitUntilIdle(in: app, file: file, line: line)
        XCTAssertFalse(app.staticTexts["已完成"].exists, file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    }

    @MainActor func testSendClearsComposerBeforeStreamFinishes() async throws {
        let app = launch()
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let emptyValue = input.value as? String
        send("streaming ui fixture", in: app)
        XCTAssertTrue(app.staticTexts["streaming ui fixture"].waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, emptyValue)
        XCTAssertTrue(app.descendants(matching: .any)["assistantReplyIndicator"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Streaming response"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Streaming response arrived incrementally and is now complete."].exists,
                       "The response must be visible before its final chunk.")
        XCTAssertTrue(app.buttons["stopRunButton"].exists)
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18765/fixture/release-stream")!)
        XCTAssertTrue(app.staticTexts["Streaming response arrived incrementally and is now complete."].waitForExistence(timeout: 15))
        waitUntilIdle(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["assistantReplyIndicator"].exists)
    }

    @MainActor func testRealToolActivityInterleavesAndSurvivesRelaunch() {
        var app = launch(timeline: true)
        send("timeline fixture", in: app)
        XCTAssertTrue(app.staticTexts["I will inspect the file first."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 15))
        waitUntilIdle(in: app)
        assertTimeline(in: app)
        app.terminate()
        app = launch(reset: false, timeline: true)
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 10))
        assertTimeline(in: app)
        XCTAssertFalse(app.staticTexts["已完成"].exists)
    }

    @MainActor func testToolPauseRequiresExplicitContinuationAcrossRelaunch() {
        var app = launch(timeline: true)
        send("tool pause fixture", in: app)
        XCTAssertTrue(app.buttons["continuePausedRunButton"].waitForExistence(timeout: 15))
        waitUntilIdle(in: app)
        XCTAssertTrue(app.buttons["endPausedRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        XCTAssertTrue(app.staticTexts["重复操作后画面没有变化，任务已暂停。请检查当前画面后再继续。"].exists)

        app.terminate()
        app = launch(reset: false, timeline: true)
        let continueButton = app.buttons["continuePausedRunButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        let automaticStart = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                       object: app.buttons["stopRunButton"])
        automaticStart.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [automaticStart], timeout: 2), .completed,
                       "Reopening the conversation must not restart the paused task.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 1)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)

        continueButton.tap()
        let continuation = "从当前画面继续我刚才的任务。先重新查看屏幕，确认哪些步骤已经完成；如果之前的操作没有进展，请换一种方式。"
        XCTAssertTrue(app.staticTexts["Fixture response: " + continuation].waitForExistence(timeout: 20))
        waitUntilIdle(in: app)
        XCTAssertTrue(app.staticTexts[continuation].exists)
        XCTAssertFalse(app.buttons["continuePausedRunButton"].exists)
        XCTAssertFalse(app.buttons["endPausedRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 1,
                       "An explicit continuation must not replay the settled tool call.")
    }

    @MainActor func testToolWithoutPrefaceKeepsUserAnchorAcrossRelaunch() {
        var app = launch(timeline: true)
        send("timeline no prose fixture", in: app)
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 15))
        waitUntilIdle(in: app)
        assertToolOnlyTimeline(in: app)
        app.terminate()
        app = launch(reset: false, timeline: true)
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 10))
        assertToolOnlyTimeline(in: app)
    }

    @MainActor private func assertToolOnlyTimeline(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let user = app.staticTexts["timeline no prose fixture"]
        let tool = app.descendants(matching: .any)["toolActivityRow"].firstMatch
        let reply = app.staticTexts["File inspection finished."]
        XCTAssertTrue(user.exists && tool.exists && reply.exists, file: file, line: line)
        XCTAssertLessThan(user.frame.midY, tool.frame.midY, file: file, line: line)
        XCTAssertLessThan(tool.frame.midY, reply.frame.midY, file: file, line: line)
        XCTAssertFalse(app.staticTexts["I will inspect the file first."].exists, file: file, line: line)
    }

    @MainActor private func assertTimeline(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let firstReply = app.staticTexts["I will inspect the file first."]
        let tool = app.descendants(matching: .any)["toolActivityRow"].firstMatch
        let finalReply = app.staticTexts["File inspection finished."]
        XCTAssertTrue(tool.exists, file: file, line: line)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 1, file: file, line: line)
        XCTAssertLessThan(firstReply.frame.midY, tool.frame.midY, file: file, line: line)
        XCTAssertLessThan(tool.frame.midY, finalReply.frame.midY, file: file, line: line)
        if !tool.isHittable { app.swipeDown() }
        tool.tap()
        XCTAssertTrue(app.staticTexts["Fixture document content"].waitForExistence(timeout: 5), file: file, line: line)
    }

    @MainActor private func waitUntilIdle(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed, file: file, line: line)
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
