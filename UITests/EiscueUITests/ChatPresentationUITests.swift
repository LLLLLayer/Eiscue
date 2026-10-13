import XCTest

/// These interaction tests never access the microphone; the audio callback and
/// hold cancellation contracts are covered by the App's unit tests.
final class ChatPresentationUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["EISCUE_TEST_MODEL_URL"] = "http://127.0.0.1:18765/v1"
        app.launch()
        XCTAssertTrue(app.buttons["composerAddButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor func testVoiceModeIsSeparateFromTextSelectionAndPreservesDraft() {
        let app = launch()
        let input = input(in: app)
        input.tap(); input.typeText("Keep my typed draft")
        app.buttons["speechInputButton"].tap()
        XCTAssertTrue(app.buttons["holdToTalkButton"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.buttons["holdToTalkButton"].frame.height, 64)
        XCTAssertGreaterThan(app.buttons["holdToTalkButton"].frame.width, 180)
        XCTAssertFalse(app.descendants(matching: .any)["messageInput"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["speechPreview"].exists)
        let voiceScreenshot = XCTAttachment(screenshot: app.screenshot())
        voiceScreenshot.name = "Dedicated hold-to-talk mode"
        voiceScreenshot.lifetime = .keepAlways
        add(voiceScreenshot)
        app.buttons["speechInputButton"].tap()
        XCTAssertEqual(self.input(in: app).value as? String, "Keep my typed draft")
        XCTAssertFalse(app.buttons["holdToTalkButton"].exists)
    }

    @MainActor func testMarkdownMessageHasTimeActionsAndNativeRangeSelection() {
        let app = launch()
        let input = input(in: app)
        input.tap(); input.typeText("markdown rendering fixture")
        app.buttons["sendMessageButton"].tap()
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 20))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["Turn ended"].exists)
        let rows = app.descendants(matching: .any)
        XCTAssertTrue(rows["markdownHeading"].exists)
        XCTAssertTrue(rows["markdownCodeBlock"].exists)
        XCTAssertTrue(rows["markdownTable"].exists)
        XCTAssertTrue(rows["markdownQuote"].exists)
        XCTAssertGreaterThanOrEqual(rows.matching(identifier: "markdownListItem").count, 2)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "messageTime").count, 2)
        XCTAssertFalse(app.buttons["messageMoreButton"].exists)
        XCTAssertFalse(app.buttons["userMessageMoreButton"].exists)
        XCTAssertTrue(app.buttons["copyMessageButton"].exists)
        XCTAssertTrue(app.buttons["shareMessageButton"].exists)
        for appearance in ["Light", "Dark"] {
            openSettings(in: app)
            let picker = app.buttons["appearancePicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.tap()
            app.buttons[appearance].tap()
            XCTAssertTrue((picker.label + (picker.value as? String ?? "")).contains(appearance))
            attachScreenshot(app, name: "Settings — \(appearance)")
            returnToAssistant(in: app)
            attachScreenshot(app, name: "Markdown message and compact actions — \(appearance)")
        }
        let heading = rows["markdownHeading"].firstMatch
        for _ in 0..<4 where !heading.isHittable { app.swipeDown() }
        XCTAssertTrue(heading.isHittable)
        let message = rows.matching(identifier: "messageBubble")
            .containing(.staticText, identifier: "markdownHeading").firstMatch
        XCTAssertTrue(message.exists)
        // Press the message's trailing space so native word selection does not
        // intercept the row's long-press context menu.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: message.frame.maxX - 8, dy: heading.frame.midY)).press(forDuration: 1)
        let selectText = app.buttons["selectMessageTextButton"]
        XCTAssertTrue(selectText.waitForExistence(timeout: 5))
        selectText.tap()
        let selectable = app.textViews["selectableMessageText"]
        XCTAssertTrue(selectable.waitForExistence(timeout: 5))
        let completeText = selectable.value as? String ?? ""
        XCTAssertTrue(completeText.contains("let answer = 42"))
        selectable.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.05)).press(forDuration: 1)
        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "Native word selection"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)
        tapEditMenu("Copy", in: app)
        app.buttons["Done"].tap()
        let destination = self.input(in: app)
        destination.tap()
        destination.press(forDuration: 1)
        tapEditMenu("Paste", in: app)
        let pasted = destination.value as? String ?? ""
        XCTAssertFalse(pasted.isEmpty)
        XCTAssertLessThan(pasted.count, completeText.count)
        XCTAssertTrue(completeText.contains(pasted), "The pasted selection must be part of the message")
    }

    @MainActor func testOnlyLatestSenderMessagesShowActionsAndOlderMessageStillShares() {
        let app = launch()
        for prompt in ["First message", "Second message"] {
            let editor = input(in: app)
            editor.tap(); editor.typeText(prompt)
            app.buttons["sendMessageButton"].tap()
            XCTAssertTrue(app.staticTexts["Fixture response: \(prompt)"].waitForExistence(timeout: 20))
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        }
        for identifier in ["userCopyMessageButton", "copyMessageButton", "userShareMessageButton", "shareMessageButton"] {
            XCTAssertEqual(app.buttons.matching(identifier: identifier).count, 1, identifier)
        }
        XCTAssertFalse(app.buttons["userMessageMoreButton"].exists)
        XCTAssertFalse(app.buttons["messageMoreButton"].exists)
        let oldMessage = app.descendants(matching: .any).matching(identifier: "messageBubble")
            .containing(.staticText, identifier: "First message").firstMatch.staticTexts["First message"]
        if !oldMessage.isHittable { app.swipeDown() }
        XCTAssertTrue(oldMessage.isHittable)
        oldMessage.press(forDuration: 1)
        tapEditMenu("Share", in: app)
        // iOS may replace the controller's root accessibility identifier when
        // its system-hosted share surface attaches. Verify the actual sheet,
        // original payload and completed Copy action, not only our marker.
        let sheet = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["ActivityListView", "messageActivityController"])).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
        XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "First message"))
            .firstMatch.waitForExistence(timeout: 3))
        let copy = sheet.cells.matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        let shareScreenshot = XCTAttachment(screenshot: app.screenshot())
        shareScreenshot.name = "Older message in native share sheet"
        shareScreenshot.lifetime = .keepAlways
        add(shareScreenshot)
        copy.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        let destination = input(in: app)
        destination.tap(); destination.press(forDuration: 1)
        tapEditMenu("Paste", in: app)
        XCTAssertEqual(destination.value as? String, "First message")
    }

    @MainActor private func input(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["messageInput"]
        let result = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        return result
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func tapEditMenu(_ title: String, in app: XCUIApplication) {
        let item = app.menuItems[title]
        if item.waitForExistence(timeout: 3) { item.tap(); return }
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 3))
        guard let button = candidates.allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail("No visible edit-menu action: \(title)")
        }
        button.tap()
    }
}
