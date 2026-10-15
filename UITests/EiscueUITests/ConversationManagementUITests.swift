import XCTest

final class ConversationManagementUITests: XCTestCase {
    @MainActor func testSwipeRenameAndBatchActionsPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["EISCUE_TEST_MODEL_URL"] = "http://127.0.0.1:18765/v1"
        app.launch()
        send("First conversation", in: app)
        openSidebar(in: app)
        app.buttons["newConversationButton"].tap()
        send("Second conversation", in: app)

        let input = app.textFields["messageInput"].exists ? app.textFields["messageInput"] : app.textViews["messageInput"]
        input.tap(); input.typeText("Keep this draft")
        swipeRightInMessages(in: app)
        XCTAssertTrue(app.buttons["sidebarSettingsButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sidebarSettingsButton"].isHittable)
        closeSidebar(in: app)
        XCTAssertEqual(input.value as? String, "Keep this draft")
        openSidebar(in: app)
        let second = row("Second conversation", in: app)
        assertUpdatedTime(for: second)
        XCTAssertFalse(app.buttons["selectConversationsButton"].exists)
        XCTAssertFalse(app.buttons["doneSelectingConversationsButton"].exists)
        second.press(forDuration: 1)
        app.buttons["renameConversationButton"].tap()
        let renameAlert = app.alerts["Rename conversation"]
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
        let name = renameAlert.textFields["Conversation name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Second conversation".count) + "Renamed conversation")
        renameAlert.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(row("Renamed conversation", in: app).waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-state" }
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        openSidebar(in: app)
        XCTAssertTrue(row("Renamed conversation", in: app).exists)
        assertUpdatedTime(for: row("Renamed conversation", in: app))
        row("First conversation", in: app).press(forDuration: 1)
        app.buttons["selectConversationButton"].tap()
        XCTAssertTrue(app.buttons["doneSelectingConversationsButton"].exists)
        app.buttons["doneSelectingConversationsButton"].tap()
        XCTAssertFalse(app.buttons["deleteSelectedConversationsButton"].exists)
        row("First conversation", in: app).press(forDuration: 1)
        app.buttons["selectConversationButton"].tap()
        row("Renamed conversation", in: app).tap()
        app.buttons["pinSelectedConversationsButton"].tap()
        XCTAssertEqual(row("First conversation", in: app).value as? String, "Pinned")
        XCTAssertEqual(row("Renamed conversation", in: app).value as? String, "Pinned")
        XCTAssertEqual(app.buttons["pinSelectedConversationsButton"].label, "Unpin")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Conversation multi-selection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["pinSelectedConversationsButton"].tap()
        XCTAssertEqual(row("First conversation", in: app).value as? String, "")
        app.buttons["deleteSelectedConversationsButton"].tap()
        XCTAssertTrue(app.buttons["confirmDeleteConversationsButton"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["confirmDeleteConversationsButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(row("First conversation", in: app).exists)
        XCTAssertFalse(row("Renamed conversation", in: app).exists)
    }

    @MainActor private func send(_ message: String, in app: XCUIApplication) {
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText(message)
        let send = app.buttons["sendMessageButton"]
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        send.tap()
        XCTAssertTrue(app.staticTexts["Fixture response: \(message)"].waitForExistence(timeout: 20))
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed)
    }

    @MainActor private func swipeRightInMessages(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "conversationRow_", title)).firstMatch
    }

    @MainActor private func assertUpdatedTime(for row: XCUIElement) {
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("The conversation row must remain accessible by its identifier and title.")
            return
        }
        let identifier = row.identifier.replacingOccurrences(of: "conversationRow_", with: "conversationUpdatedAt_")
        let updatedTime = row.staticTexts[identifier]
        XCTAssertTrue(updatedTime.waitForExistence(timeout: 5))
        XCTAssertTrue(updatedTime.label.hasPrefix("Updated "))
        XCTAssertGreaterThan(updatedTime.label.count, "Updated ".count)
    }
}
