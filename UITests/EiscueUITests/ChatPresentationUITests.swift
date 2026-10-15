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

    @MainActor func testLongHistoryStartsAtLatestAndKeepsReadingPositionWhileTyping() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "--long-conversation-fixture", "-AppleLanguages", "(en)"]
        app.launchEnvironment["EISCUE_TEST_MODEL_URL"] = "http://127.0.0.1:18765/v1"
        app.launch()
        let latest = app.staticTexts["LATEST_HISTORY_MESSAGE"]
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        XCTAssertTrue(latest.isHittable)
        let scroll = app.scrollViews["conversationScrollView"]
        XCTAssertLessThan(app.descendants(matching: .any).matching(identifier: "messageBubble").count, 60,
                          "Offscreen history must not create hundreds of message rows.")
        scroll.swipeDown(); scroll.swipeDown()
        XCTAssertFalse(latest.isHittable)
        let input = input(in: app)
        input.tap(); input.typeText("Draft while reading history")
        XCTAssertFalse(latest.isHittable, "Typing must not force the reader back to the newest message.")
        attachScreenshot(app, name: "Long history stays at reading position")
        app.buttons["sendMessageButton"].tap()
        let reply = app.staticTexts["Fixture response: Draft while reading history"]
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        XCTAssertTrue(reply.isHittable, "Sending a new message resumes following the conversation.")
    }

    @MainActor func testVoiceModeIsSeparateFromTextSelectionAndPreservesDraft() {
        let app = launch()
        let composer = app.otherElements["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let restingBottom = composer.frame.maxY
        let singleLineHeight = composer.frame.height
        var draft = ""
        for addition in ["", "Keep my typed draft", "\nSecond line\nThird line\nFourth line"] {
            if !addition.isEmpty {
                let input = input(in: app)
                input.tap(); input.typeText(addition)
                draft += addition
            }
            let textFrame = composer.frame
            let switchFrame = app.buttons["speechInputButton"].frame
            if draft.contains("\n") { XCTAssertGreaterThan(textFrame.height, singleLineHeight + 30) }
            app.buttons["speechInputButton"].tap()
            let hold = app.buttons["holdToTalkButton"]
            XCTAssertTrue(hold.waitForExistence(timeout: 5))
            XCTAssertEqual(composer.frame.height, textFrame.height, accuracy: 1,
                           "Switching input mode must preserve the editor's height, including a multiline draft.")
            XCTAssertEqual(composer.frame.maxY, restingBottom, accuracy: 1,
                           "Voice guidance must not add space beneath the input bar.")
            XCTAssertEqual(app.buttons["speechInputButton"].frame.midX, switchFrame.midX, accuracy: 1)
            XCTAssertEqual(hold.frame.height, 44, accuracy: 1)
            XCTAssertGreaterThan(hold.frame.width, 180)
            XCTAssertEqual(hold.label, "Tap to talk")
            XCTAssertEqual(hold.frame.midY, app.buttons["speechInputButton"].frame.midY, accuracy: 1)
            XCTAssertEqual(app.buttons["composerAddButton"].frame.midY, hold.frame.midY, accuracy: 1)
            XCTAssertFalse(app.descendants(matching: .any)["messageInput"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["speechPreview"].exists)
            XCTAssertFalse(app.otherElements["speechRecordingOverlay"].exists,
                           "Choosing voice mode alone must not imply microphone capture.")
            XCTAssertTrue(app.buttons["sendMessageButton"].exists)
            XCTAssertFalse(app.buttons["sendMessageButton"].isEnabled)
            attachScreenshot(app, name: "Stable voice composer — \(draft.isEmpty ? "empty" : draft.contains("\n") ? "multiline" : "single line")")
            app.buttons["speechInputButton"].tap()
            let editor = self.input(in: app)
            if !draft.isEmpty { XCTAssertEqual(editor.value as? String, draft) }
            XCTAssertEqual(composer.frame.height, textFrame.height, accuracy: 1)
            XCTAssertFalse(app.buttons["holdToTalkButton"].exists)
        }
    }

    @MainActor func testRecordingOverlayStaysAboveStableComposerAndDismissesAfterFinish() {
        for appearance in ["Light", "Dark"] {
            let app = launchSpeechRecordingFixture()
            openSettings(in: app)
            app.buttons["appearancePicker"].tap()
            app.buttons[appearance].tap()
            returnToAssistant(in: app)
            let draft = "Keep this draft\nAnd the second line\nAnd the third line"
            let editor = input(in: app)
            editor.tap(); editor.typeText(draft)
            app.buttons["speechInputButton"].tap()
            let record = app.buttons["holdToTalkButton"]
            XCTAssertTrue(record.waitForExistence(timeout: 5))
            let composer = app.otherElements["messageComposer"]
            let originalFrame = composer.frame
            let overlay = app.otherElements["speechRecordingOverlay"]
            XCTAssertFalse(overlay.exists)
            attachScreenshot(app, name: "Voice composer before recording — \(appearance)")
            startFixtureRecording(in: app)
            XCTAssertTrue(overlay.waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["speechRecordingStatus"].label, "Listening…")
            XCTAssertEqual(composer.frame.height, originalFrame.height, accuracy: 1)
            XCTAssertEqual(composer.frame.maxY, originalFrame.maxY, accuracy: 1)
            XCTAssertLessThanOrEqual(overlay.frame.maxY, composer.frame.minY,
                                    "The message scrim must stop above the persistent composer.")
            XCTAssertGreaterThanOrEqual(overlay.frame.maxY, composer.frame.minY - 14,
                                       "Only the composer's 12-point top padding may separate it from the scrim.")
            XCTAssertTrue(app.buttons["cancelDictationButton"].isHittable)
            XCTAssertTrue(app.buttons["speechInputButton"].isHittable)
            XCTAssertTrue(record.isHittable)
            attachScreenshot(app, name: "Recording feedback with silent fixture and stable multiline composer — \(appearance)")
            record.tap()
            let finishing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Transcribing…"),
                                                      object: app.staticTexts["speechRecordingStatus"])
            XCTAssertEqual(XCTWaiter.wait(for: [finishing], timeout: 2), .completed)
            XCTAssertEqual(composer.frame.height, originalFrame.height, accuracy: 1)
            XCTAssertTrue(overlay.waitForNonExistence(timeout: 8))
            XCTAssertEqual(input(in: app).value as? String, draft)
            app.terminate()
        }
    }

    @MainActor func testRecordingOverlayAllowsCancelAndKeyboardWithoutLosingDraft() {
        let app = launchSpeechRecordingFixture()
        let draft = "Preserve my typed text"
        let editor = input(in: app)
        editor.tap(); editor.typeText(draft)
        let overlay = app.otherElements["speechRecordingOverlay"]
        for control in ["cancelDictationButton", "speechInputButton"] {
            app.buttons["speechInputButton"].tap()
            XCTAssertTrue(app.buttons["holdToTalkButton"].waitForExistence(timeout: 5))
            startFixtureRecording(in: app)
            XCTAssertTrue(overlay.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons[control].isHittable)
            app.buttons[control].tap()
            XCTAssertTrue(overlay.waitForNonExistence(timeout: 8))
            XCTAssertEqual(input(in: app).value as? String, draft)
        }
    }

    @MainActor func testVoiceModeSwitchKeepsRemoteControlConnectedAndPreservesDraft() throws {
        let app = try launchSpeechConnectionFixture()
        let selectedRoute = try XCTUnwrap(app.buttons["deviceConnectionMethodPicker"].value as? String)
        let selectedBackend = try XCTUnwrap(app.buttons["deviceControlBackendPicker"].value as? String)
        returnToAssistant(in: app)
        let deviceLink = app.buttons["deviceNavigationLink"]
        let connectedStatus = try XCTUnwrap(deviceLink.value as? String)
        let composer = app.otherElements["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let restingBottom = composer.frame.maxY
        let draft = "Keep this draft\nAnd this second line\nAnd this third line"
        let editor = input(in: app)
        editor.tap(); editor.typeText(draft)
        let originalFrame = composer.frame
        app.buttons["speechInputButton"].tap()
        let record = app.buttons["holdToTalkButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertEqual(record.label, "Tap to talk")
        XCTAssertFalse(app.staticTexts["speechNotice"].exists)
        XCTAssertEqual(deviceLink.value as? String, connectedStatus,
                       "Switching input mode must retain device control until recording is requested.")
        XCTAssertEqual(composer.frame.height, originalFrame.height, accuracy: 1)
        XCTAssertEqual(composer.frame.maxY, restingBottom, accuracy: 1)
        XCTAssertFalse(app.descendants(matching: .any)["messageInput"].exists)
        XCTAssertFalse(app.buttons["sendMessageButton"].isEnabled)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attachScreenshot(app, name: "Voice composer retains device control")

        // Merely switching input modes never starts recording or a handoff.
        app.buttons["speechInputButton"].tap()
        XCTAssertTrue(record.waitForNonExistence(timeout: 5))
        XCTAssertEqual(input(in: app).value as? String, draft)
        XCTAssertEqual(composer.frame.height, originalFrame.height, accuracy: 1)
        XCTAssertEqual(deviceLink.value as? String, connectedStatus)
        XCTAssertFalse(app.staticTexts["speechNotice"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        openDevice(in: app)
        XCTAssertTrue(app.buttons["disconnectDeviceButton"].waitForExistence(timeout: 5),
                      "Switching back without recording must retain the original control connection.")
        XCTAssertEqual(app.buttons["deviceConnectionMethodPicker"].value as? String, selectedRoute)
        XCTAssertEqual(app.buttons["deviceControlBackendPicker"].value as? String, selectedBackend)
    }

    @MainActor func testRecordingTemporarilyReleasesRemoteControlAndRestoresAfterFinish() throws {
        let app = try launchSpeechConnectionFixture()
        let selectedRoute = try XCTUnwrap(app.buttons["deviceConnectionMethodPicker"].value as? String)
        let selectedBackend = try XCTUnwrap(app.buttons["deviceControlBackendPicker"].value as? String)
        returnToAssistant(in: app)
        let deviceLink = app.buttons["deviceNavigationLink"]
        let connectedStatus = try XCTUnwrap(deviceLink.value as? String)
        let draft = "Keep this draft after recording"
        let editor = input(in: app)
        editor.tap(); editor.typeText(draft)
        app.buttons["speechInputButton"].tap()
        let record = app.buttons["holdToTalkButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertEqual(deviceLink.value as? String, connectedStatus)

        startFixtureRecording(in: app)
        XCTAssertNotEqual(deviceLink.value as? String, connectedStatus,
                          "The recording trigger must release control before microphone capture starts.")
        XCTAssertFalse(app.buttons["sendMessageButton"].isEnabled)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        record.tap()
        XCTAssertTrue(record.waitForNonExistence(timeout: 8))
        XCTAssertEqual(input(in: app).value as? String, draft)
        let reconnected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", connectedStatus), object: deviceLink)
        XCTAssertEqual(XCTWaiter.wait(for: [reconnected], timeout: 5), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        openDevice(in: app)
        XCTAssertTrue(app.buttons["disconnectDeviceButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["deviceConnectionMethodPicker"].value as? String, selectedRoute)
        XCTAssertEqual(app.buttons["deviceControlBackendPicker"].value as? String, selectedBackend)
    }

    @MainActor func testRecordingReconnectFailurePreservesDraftAndShowsNotice() throws {
        let app = try launchSpeechConnectionFixture(failsReconnection: true)
        returnToAssistant(in: app)
        let draft = "Keep this draft after reconnect fails"
        let editor = input(in: app)
        editor.tap(); editor.typeText(draft)
        let composer = app.otherElements["messageComposer"]
        let originalHeight = composer.frame.height
        app.buttons["speechInputButton"].tap()
        XCTAssertTrue(app.buttons["holdToTalkButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["speechNotice"].exists)
        startFixtureRecording(in: app)
        app.buttons["speechInputButton"].tap()
        let notice = app.staticTexts["speechNotice"]
        let reconnectFailure = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@",
            "Couldn’t reconnect device control. Reconnect from the device page."), object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [reconnectFailure], timeout: 8), .completed)
        XCTAssertEqual(input(in: app).value as? String, draft)
        XCTAssertEqual(composer.frame.height, originalHeight, accuracy: 1)
        XCTAssertFalse(app.buttons["holdToTalkButton"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attachScreenshot(app, name: "Reconnect failure preserves the text draft")
        openDevice(in: app)
        XCTAssertTrue(app.buttons["connectDeviceButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["disconnectDeviceButton"].exists)
    }

    @MainActor func testFinishedDictationShowsCancellableDeviceRestorationOutsideVoiceButton() throws {
        let app = try launchSpeechConnectionFixture(delaysReconnection: true)
        returnToAssistant(in: app)
        let draft = "Keep draft"
        let editor = input(in: app)
        editor.tap(); editor.typeText(draft)
        let composer = app.otherElements["messageComposer"]
        let originalHeight = composer.frame.height
        let voiceMode = app.buttons["speechInputButton"]
        voiceMode.tap()
        startFixtureRecording(in: app)
        app.buttons["holdToTalkButton"].tap()
        let status = app.staticTexts["speechDeviceRestorationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.label, "Reconnecting device…")
        XCTAssertEqual(composer.frame.height, originalHeight, accuracy: 1,
                       "Connection restoration must not add a row that moves the composer and message list.")
        XCTAssertLessThan(status.frame.maxY, composer.frame.minY)
        XCTAssertFalse(app.otherElements["speechRecordingOverlay"].exists)
        XCTAssertEqual(voiceMode.label, "Switch to voice input")
        XCTAssertEqual(voiceMode.activityIndicators.count, 0,
                       "Completed speech must not retain a device-connection spinner in the voice button.")
        attachScreenshot(app, name: "Finished dictation with cancellable restoration overlay")
        let editableDraft = input(in: app)
        XCTAssertEqual(editableDraft.value as? String, draft)
        editableDraft.tap(); editableDraft.typeText(" now")
        let editedValue = try XCTUnwrap(editableDraft.value as? String)
        XCTAssertEqual(editedValue.replacingOccurrences(of: " now", with: ""), draft)
        XCTAssertEqual(editedValue.count, draft.count + " now".count)
        let editedHeight = composer.frame.height
        XCTAssertFalse(app.buttons["sendMessageButton"].isEnabled)
        app.buttons["cancelSpeechDeviceRestorationButton"].tap()
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.frame.height, editedHeight, accuracy: 1)
        let readyToSend = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                   object: app.buttons["sendMessageButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [readyToSend], timeout: 5), .completed)
        XCTAssertEqual(input(in: app).value as? String, editedValue)
        XCTAssertTrue(voiceMode.isEnabled)
        openDevice(in: app)
        XCTAssertTrue(app.buttons["connectDeviceButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["disconnectDeviceButton"].exists)
    }

    @MainActor func testMarkdownMessageLongPressSelectsAndCopiesAllTextInline() {
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
        XCTAssertFalse(app.buttons["copyMessageButton"].exists)
        XCTAssertFalse(app.buttons["selectMessageTextButton"].exists)
        XCTAssertFalse(app.buttons["shareMessageButton"].exists)
        for appearance in ["Light", "Dark"] {
            openSettings(in: app)
            let picker = app.buttons["appearancePicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.tap()
            app.buttons[appearance].tap()
            XCTAssertTrue((picker.label + (picker.value as? String ?? "")).contains(appearance))
            attachScreenshot(app, name: "Settings — \(appearance)")
            returnToAssistant(in: app)
            attachScreenshot(app, name: "Markdown message and time footer — \(appearance)")
        }
        let heading = rows["markdownHeading"].firstMatch
        for _ in 0..<4 where !heading.isHittable { app.swipeDown() }
        XCTAssertTrue(heading.isHittable)
        let message = rows.matching(identifier: "messageBubble")
            .containing(.staticText, identifier: "markdownHeading").firstMatch
        XCTAssertTrue(message.exists)
        let time = app.staticTexts.matching(identifier: "messageTime").element(boundBy: 1)
        let composer = app.otherElements["messageComposer"]
        XCTAssertTrue(time.exists)
        XCTAssertTrue(composer.exists)
        let messageFrame = message.frame, timeFrame = time.frame, composerFrame = composer.frame
        heading.press(forDuration: 1)
        let inlineMessage = rows.matching(identifier: "messageBubble")
            .containing(.textView, identifier: "selectableMessageText").firstMatch
        let selectable = inlineMessage.textViews["selectableMessageText"]
        XCTAssertTrue(selectable.waitForExistence(timeout: 5))
        assertUnchangedFrame(inlineMessage, from: messageFrame, context: "Markdown bubble while selected")
        assertUnchangedFrame(time, from: timeFrame, context: "Markdown timestamp while selected")
        assertUnchangedFrame(composer, from: composerFrame, context: "Composer while Markdown is selected")
        assertNoMessageContextActions(in: app)
        XCTAssertFalse(app.sheets.firstMatch.exists, "Text selection must remain inside the original message.")
        XCTAssertFalse(app.buttons["Done"].exists, "Inline selection must not require dismissing a second page.")
        XCTAssertTrue(self.input(in: app).isHittable)
        let completeText = selectable.value as? String ?? ""
        XCTAssertTrue(completeText.contains("let answer = 42"))
        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "Long press selects the entire original message"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)
        // One long press must select the entire message and offer native Copy.
        tapEditMenu("Copy", in: app)
        XCTAssertTrue(selectable.waitForNonExistence(timeout: 5))
        XCTAssertTrue(rows["markdownHeading"].waitForExistence(timeout: 5))
        assertUnchangedFrame(message, from: messageFrame, context: "Markdown bubble after Copy")
        assertUnchangedFrame(time, from: timeFrame, context: "Markdown timestamp after Copy")
        assertUnchangedFrame(composer, from: composerFrame, context: "Composer after Markdown Copy")
        let destination = self.input(in: app)
        destination.tap()
        destination.press(forDuration: 1)
        tapEditMenu("Paste", in: app)
        let pasted = destination.value as? String ?? ""
        XCTAssertFalse(pasted.isEmpty)
        XCTAssertEqual(pasted, completeText, "Copy must include all rendered message text, including offscreen blocks.")
    }

    @MainActor func testOnlyLatestSenderMessagesShowTimeAndOlderMessageCopiesAllText() {
        let app = launch()
        for prompt in ["First message", "Second message"] {
            let editor = input(in: app)
            editor.tap(); editor.typeText(prompt)
            app.buttons["sendMessageButton"].tap()
            XCTAssertTrue(app.staticTexts["Fixture response: \(prompt)"].waitForExistence(timeout: 20))
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        }
        assertNoMessageContextActions(in: app)
        XCTAssertEqual(app.staticTexts.matching(identifier: "messageTime").count, 2)
        XCTAssertFalse(app.buttons["userMessageMoreButton"].exists)
        XCTAssertFalse(app.buttons["messageMoreButton"].exists)
        let oldMessage = app.descendants(matching: .any).matching(identifier: "messageBubble")
            .containing(.staticText, identifier: "First message").firstMatch
        if !oldMessage.isHittable { app.swipeDown() }
        XCTAssertTrue(oldMessage.isHittable)
        oldMessage.staticTexts["First message"].press(forDuration: 1)
        let selectable = app.descendants(matching: .any).matching(identifier: "messageBubble")
            .containing(.textView, identifier: "selectableMessageText").firstMatch.textViews["selectableMessageText"]
        XCTAssertTrue(selectable.waitForExistence(timeout: 5))
        XCTAssertEqual(selectable.value as? String, "First message")
        assertNoMessageContextActions(in: app)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        attachScreenshot(app, name: "Older user message directly selected in full")
        tapEditMenu("Copy", in: app)
        XCTAssertTrue(selectable.waitForNonExistence(timeout: 5))
        let destination = input(in: app)
        destination.tap(); destination.press(forDuration: 1)
        tapEditMenu("Paste", in: app)
        XCTAssertEqual(destination.value as? String, "First message")
    }

    @MainActor private func launchSpeechConnectionFixture(failsReconnection: Bool = false,
                                                         delaysReconnection: Bool = false) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            throw XCTSkip("The CoreDevice media handoff applies to iOS 27.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "--local-device-ready-fixture",
                               "--speech-device-ready-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if failsReconnection { app.launchArguments.append("--speech-device-reconnect-failure") }
        if delaysReconnection { app.launchArguments.append("--speech-device-reconnect-delay") }
        app.launch()
        XCTAssertTrue(app.staticTexts["devicePairingComplete"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["disconnectDeviceButton"].exists)
        return app
    }

    @MainActor private func launchSpeechRecordingFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "--speech-recording-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["composerAddButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func startFixtureRecording(in app: XCUIApplication) {
        // This explicit fixture uses fake authorization/capture, while running
        // the normal pre-recording handoff and finish/cancel lifecycle.
        let record = app.buttons["holdToTalkButton"]
        record.tap()
        let recording = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Listening…"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 5), .completed)
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

    @MainActor private func assertNoMessageContextActions(in app: XCUIApplication) {
        for identifier in ["selectMessageTextButton", "userCopyMessageButton", "copyMessageButton",
                           "userShareMessageButton", "shareMessageButton", "messageRunHistoryButton"] {
            XCTAssertFalse(app.buttons[identifier].exists, "Text messages use native selection without an intermediate action menu.")
        }
        XCTAssertFalse(app.buttons["Edit as a new message"].exists)
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

/// Explicit opt-in: captures briefly on a real phone, never sends a message,
/// saves audio, records recognized text in the report, or overrides language.
final class SpeechCaptureAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Microphone capture requires a physical iPhone.")
        #else
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_SPEECH_TEST"] == "1" else {
            throw XCTSkip("Run explicitly with TEST_RUNNER_EISCUE_REAL_SPEECH_TEST=1.")
        }
        #endif
    }

    @MainActor func testTapStartsActualMicrophoneCapture() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "--speech-diagnostics"]
        app.launch()
        let mode = app.buttons["speechInputButton"]
        guard mode.waitForExistence(timeout: 10) else {
            app.terminate(); XCTFail("The composer did not open."); return
        }
        mode.tap()
        let record = app.buttons["holdToTalkButton"]
        guard record.waitForExistence(timeout: 5) else {
            app.terminate(); XCTFail("The dictation control did not open."); return
        }
        record.tap()
        let hasAudio = NSPredicate(format: "value CONTAINS %@", "signal=true")
        let captured = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hasAudio, object: record)], timeout: 12)
        let metadata = record.value as? String ?? "no state"
        app.terminate()
        XCTAssertEqual(captured, .completed, "Actual microphone capture: \(metadata)")
        let attachment = XCTAttachment(string: metadata)
        attachment.name = "Microphone capture metadata only"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
