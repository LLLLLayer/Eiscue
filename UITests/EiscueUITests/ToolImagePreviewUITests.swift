import XCTest

final class ToolImagePreviewUITests: XCTestCase {
    @MainActor func testObservedImageExpandsAndOpensViewerInLightAndDarkAppearance() {
        for dark in [false, true] {
            let app = launch(dark: dark)
            let disclosure = app.buttons["toolActivityDisclosureButton"]
            XCTAssertEqual(app.buttons.matching(identifier: "toolActivityDisclosureButton").count, 1)
            XCTAssertTrue(disclosure.label.contains("已查看 1 张图像"))
            XCTAssertFalse(app.buttons["toolActivityImageThumbnail"].exists)
            disclosure.tap()
            let thumbnail = app.buttons["toolActivityImageThumbnail"]
            XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
            XCTAssertEqual(thumbnail.frame.width, 104, accuracy: 1)
            XCTAssertEqual(thumbnail.frame.height, 112, accuracy: 1)
            attach(app, name: "Tool image thumbnail and compact footer — \(dark ? "Dark" : "Light")")
            let previousToolbarFrame = app.buttons["deviceNavigationLink"].frame
            thumbnail.tap()
            let viewer = app.descendants(matching: .any)["toolActivityImageViewer"].firstMatch
            XCTAssertTrue(viewer.waitForExistence(timeout: 5))
            let close = app.buttons["closeToolImagePreviewButton"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertEqual(close.frame.midX, previousToolbarFrame.midX, accuracy: 2)
            XCTAssertEqual(close.frame.midY, previousToolbarFrame.midY, accuracy: 2)
            XCTAssertFalse(app.sheets.firstMatch.exists, "Chat images use an in-place zoom overlay.")
            attach(app, name: "Tool image viewer — \(dark ? "Dark" : "Light")")
            close.tap()
            XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
            XCTAssertTrue(thumbnail.exists)
            disclosure.tap()
            XCTAssertTrue(thumbnail.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor func testMetadataAndErrorsStayCollapsedAndFootersOnlyShowTime() {
        let app = launch()
        let rows = app.descendants(matching: .any).matching(identifier: "toolActivityRow")
        XCTAssertEqual(rows.count, 4)
        let unavailable = rows.allElementsBoundByIndex.filter { !$0.buttons["toolActivityDisclosureButton"].exists }
        XCTAssertEqual(unavailable.count, 3, "Text, failed images and an old metadata-only image cannot expand.")
        for row in unavailable {
            row.tap()
            XCTAssertFalse(app.buttons["toolActivityImageThumbnail"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["toolActivityImageViewer"].exists)
        }
        for rawOutput in ["INTERNAL_TEXT_OUTPUT", "INTERNAL_ERROR_OUTPUT", "old-metadata-only"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", rawOutput)).firstMatch.exists)
        }
        let times = app.staticTexts.matching(identifier: "messageTime").allElementsBoundByIndex
        XCTAssertEqual(times.count, 2)
        for identifier in ["copyMessageButton", "shareMessageButton", "userCopyMessageButton", "userShareMessageButton"] {
            XCTAssertFalse(app.buttons[identifier].exists)
        }
        attach(app, name: "Non-expandable metadata and timestamp-only footers")
    }

    @MainActor func testContextMenusMatchBubbleAndConversationInBothAppearances() {
        for dark in [false, true] {
            let app = launch(dark: dark)
            let bubble = app.descendants(matching: .any).matching(identifier: "messageBubble").firstMatch
            bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).press(forDuration: 1)
            XCTAssertTrue(app.buttons["userCopyMessageButton"].waitForExistence(timeout: 3))
            attach(app, name: "User bubble context menu — \(dark ? "Dark" : "Light")")
            app.buttons["userCopyMessageButton"].tap()
            openSidebar(in: app)
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversationRow_")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.press(forDuration: 1)
            XCTAssertTrue(app.buttons["renameConversationButton"].waitForExistence(timeout: 3))
            attach(app, name: "Conversation context menu — \(dark ? "Dark" : "Light")")
            app.terminate()
        }
    }

    @MainActor func testRunToolDetailShowsSourceMarkerAndResultImage() {
        let app = launch(extra: ["--run-tool-detail-fixture"])
        app.buttons["conversationMenuButton"].tap()
        app.buttons["conversationRunHistoryButton"].tap()
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI fixture")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        XCTAssertTrue(app.staticTexts["runTimelineHeader"].waitForExistence(timeout: 5))
        let step = app.buttons["runToolDetail_preview:tap"]
        for _ in 0..<4 where !step.isHittable { app.swipeUp() }
        XCTAssertTrue(step.isHittable); step.tap()
        let images = app.buttons.matching(identifier: "runToolImageThumbnail")
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["runToolCoordinates"].label.contains("284"))
        attach(app, name: "Run detail — input screenshot with tap marker")
        images.firstMatch.tap()
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].waitForExistence(timeout: 3))
        attach(app, name: "Run detail — fullscreen marked screenshot")
        app.buttons["closeToolImagePreviewButton"].tap()
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].waitForNonExistence(timeout: 3))
        for _ in 0..<4 where !app.descendants(matching: .any)["runToolOutput"].firstMatch.isHittable { app.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any)["runToolInput"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["runToolOutput"].firstMatch.label.contains("22222222"))
    }

    @MainActor private func launch(dark: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "--tool-image-preview-fixture",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments += extra
        if dark { app.launchArguments.append("--tool-image-preview-dark") }
        app.launch()
        XCTAssertTrue(app.buttons["toolActivityDisclosureButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
