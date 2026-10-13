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
            thumbnail.tap()
            let viewer = app.descendants(matching: .any)["toolActivityImageViewer"].firstMatch
            XCTAssertTrue(viewer.waitForExistence(timeout: 5))
            let close = app.buttons["closeToolImagePreviewButton"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            attach(app, name: "Tool image viewer — \(dark ? "Dark" : "Light")")
            close.tap()
            XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
            XCTAssertTrue(thumbnail.exists)
            disclosure.tap()
            XCTAssertTrue(thumbnail.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor func testMetadataAndErrorsStayCollapsedAndMessageActionsAreCompact() {
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
        for (copyID, shareID) in [("copyMessageButton", "shareMessageButton"), ("userCopyMessageButton", "userShareMessageButton")] {
            let copy = app.buttons[copyID]; let share = app.buttons[shareID]
            XCTAssertTrue(copy.exists); XCTAssertTrue(share.exists)
            guard let time = times.min(by: { abs($0.frame.midY - copy.frame.midY) < abs($1.frame.midY - copy.frame.midY) }) else {
                XCTFail("Missing message time"); continue
            }
            let gap = copy.frame.minX - time.frame.maxX
            XCTAssertGreaterThanOrEqual(gap, 0)
            XCTAssertLessThanOrEqual(gap, 12, "Time should sit next to the copy/share actions.")
            for button in [copy, share] {
                XCTAssertEqual(button.frame.width, 24, accuracy: 1)
                XCTAssertEqual(button.frame.height, 32, accuracy: 1)
            }
        }
        attach(app, name: "Non-expandable activity metadata and compact message actions")
    }

    @MainActor private func launch(dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "--tool-image-preview-fixture",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
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
