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

    @MainActor func testFittedImageShortDragSnapsBackAndDownwardSwipeDismisses() {
        let app = launch()
        app.buttons["toolActivityDisclosureButton"].tap()
        let thumbnail = app.buttons["toolActivityImageThumbnail"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        thumbnail.tap()
        let viewer = app.descendants(matching: .any)["toolActivityImageViewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        let originalFrame = viewer.frame
        let start = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 24)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(viewer.exists, "A short, slow drag must leave the fitted image open.")
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].isHittable)
        XCTAssertEqual(viewer.frame.minY, originalFrame.minY, accuracy: 2)
        XCTAssertEqual(viewer.frame.height, originalFrame.height, accuracy: 2)
        attach(app, name: "Tool image — short drag returned to fitted position")
        swipeImageVertically(viewer)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(thumbnail.isHittable)
    }

    @MainActor func testFittedImageShortHorizontalDragSnapsBackAndBothSidewaysSwipesDismiss() {
        let app = launch()
        app.buttons["toolActivityDisclosureButton"].tap()
        let thumbnail = app.buttons["toolActivityImageThumbnail"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        thumbnail.tap()
        let viewer = app.descendants(matching: .any)["toolActivityImageViewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        let originalFrame = viewer.frame
        let start = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -24, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(viewer.exists, "A short, slow horizontal drag must leave the fitted image open.")
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].isHittable)
        XCTAssertEqual(viewer.frame.minX, originalFrame.minX, accuracy: 2)
        XCTAssertEqual(viewer.frame.width, originalFrame.width, accuracy: 2)
        attach(app, name: "Tool image — short horizontal drag returned to fitted position")
        swipeImageHorizontally(viewer)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(thumbnail.isHittable)
        thumbnail.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        swipeImageHorizontally(viewer, left: false)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(thumbnail.isHittable)
    }

    @MainActor func testZoomedImagePansBeforeResetAllowsSwipeDismissal() {
        let app = launch()
        app.buttons["toolActivityDisclosureButton"].tap()
        let thumbnail = app.buttons["toolActivityImageThumbnail"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        thumbnail.tap()
        let viewer = app.descendants(matching: .any)["toolActivityImageViewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        viewer.doubleTap()
        swipeImageVertically(viewer)
        XCTAssertTrue(viewer.exists, "A vertical pan of a zoomed image must not dismiss the viewer.")
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].isHittable)
        attach(app, name: "Tool image — zoomed vertical pan remains open")
        swipeImageHorizontally(viewer)
        XCTAssertTrue(viewer.exists, "A horizontal pan of a zoomed image must not dismiss the viewer.")
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].isHittable)
        attach(app, name: "Tool image — zoomed horizontal pan remains open")
        viewer.doubleTap()
        viewer.pinch(withScale: 2, velocity: 1)
        swipeImageVertically(viewer)
        XCTAssertTrue(viewer.exists, "A vertical pan after pinch zoom must not dismiss the viewer.")
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].isHittable)
        attach(app, name: "Tool image — pinch zoom vertical pan remains open")
        viewer.doubleTap()
        swipeImageVertically(viewer, up: true)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(thumbnail.isHittable)
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

    @MainActor func testMessageSelectionAndConversationMenuInBothAppearances() {
        for dark in [false, true] {
            let app = launch(dark: dark)
            var draft = ""
            for (index, text) in ["查看当前屏幕", "屏幕显示的是外观设置。"].enumerated() {
                let bubble = app.descendants(matching: .any).matching(identifier: "messageBubble").element(boundBy: index)
                XCTAssertTrue(bubble.isHittable)
                bubble.press(forDuration: 1)
                let selectable = bubble.textViews["selectableMessageText"]
                XCTAssertTrue(selectable.waitForExistence(timeout: 5))
                for identifier in ["selectMessageTextButton", "userCopyMessageButton", "copyMessageButton",
                                   "userShareMessageButton", "shareMessageButton", "messageRunHistoryButton"] {
                    XCTAssertFalse(app.buttons[identifier].exists)
                }
                XCTAssertFalse(app.buttons["编辑为新消息"].exists)
                XCTAssertEqual(selectable.value as? String, text)
                XCTAssertFalse(app.sheets.firstMatch.exists)
                attach(app, name: "\(index == 0 ? "User" : "Assistant") direct native selection — \(dark ? "Dark" : "Light")")
                let composer = app.textFields["messageInput"].exists ? app.textFields["messageInput"] : app.textViews["messageInput"]
                XCTAssertTrue(composer.isHittable)
                composer.tap()
                XCTAssertTrue(selectable.waitForNonExistence(timeout: 5), "Returning to the composer must end inline selection.")
                if !draft.isEmpty {
                    XCTAssertEqual(composer.value as? String, draft, "Ending message selection must preserve the existing draft.")
                }
                let addition = index == 0 ? "Draft" : " after selection"
                composer.typeText(addition)
                let edited = composer.value as? String ?? ""
                // Tapping the field chooses the insertion point. Verify that
                // typing preserves the draft without assuming the caret is at its end.
                XCTAssertEqual(edited.count, draft.count + addition.count)
                XCTAssertEqual(edited.replacingOccurrences(of: addition, with: ""), draft)
                draft = edited
            }
            openSidebar(in: app)
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversationRow_")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.press(forDuration: 1)
            XCTAssertTrue(app.buttons["renameConversationButton"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["renameConversationButton"].label, "重命名")
            XCTAssertEqual(app.buttons["deleteConversationButton"].label, "删除")
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
        let coordinates = app.descendants(matching: .any).matching(identifier: "runToolCoordinates").firstMatch
        // The iPad task sheet lazily creates the row below the source image.
        for _ in 0..<4 where !coordinates.exists {
            app.collectionViews.allElementsBoundByIndex.last(where: \.isHittable)?.swipeUp()
        }
        XCTAssertTrue(coordinates.waitForExistence(timeout: 3))
        XCTAssertTrue(coordinates.label.contains("284"))
        attach(app, name: "Run detail — input screenshot with tap marker")
        for _ in 0..<4 where !images.firstMatch.isHittable {
            app.collectionViews.allElementsBoundByIndex.last(where: \.isHittable)?.swipeDown()
        }
        images.firstMatch.tap()
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].waitForExistence(timeout: 3))
        let viewer = app.descendants(matching: .any)["toolActivityImageViewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 3))
        attach(app, name: "Run detail — fullscreen marked screenshot")
        swipeImageVertically(viewer)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closeToolImagePreviewButton"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(images.firstMatch.isHittable)
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

    @MainActor private func swipeImageVertically(_ viewer: XCUIElement, up: Bool = false) {
        let start = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.78 : 0.3))
        let end = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.78))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor private func swipeImageHorizontally(_ viewer: XCUIElement, left: Bool = true) {
        let distance = min(220, viewer.frame.width - 96)
        XCTAssertGreaterThanOrEqual(distance, 160)
        let center = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let start = center.withOffset(CGVector(dx: left ? distance / 2 : -distance / 2, dy: 0))
        let end = center.withOffset(CGVector(dx: left ? -distance / 2 : distance / 2, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
