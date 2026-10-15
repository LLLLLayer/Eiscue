import XCTest

extension XCTestCase {
    @MainActor
    func assertUnchangedFrame(_ element: XCUIElement, from expected: CGRect, context: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, context, file: file, line: line)
        let actual = element.frame
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, "\(context): x", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, "\(context): y", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, "\(context): width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, "\(context): height", file: file, line: line)
    }

    @MainActor
    func openSidebar(in app: XCUIApplication) {
        let settings = app.buttons["sidebarSettingsButton"]
        if settings.isHittable { return } // A wide iPad keeps the sidebar visible.
        let history = app.buttons["historyButton"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
    }

    @MainActor
    func closeSidebar(in app: XCUIApplication) {
        let close = app.buttons["closeSidebarButton"]
        if close.isHittable { close.tap() }
    }

    @MainActor
    func returnToAssistant(in app: XCUIApplication) {
        closeSidebar(in: app)
        for _ in 0..<5 {
            if app.buttons["deviceNavigationLink"].isHittable { return }
            let back = app.navigationBars.buttons.allElementsBoundByIndex.first { $0.isHittable }
            guard let back else { break }
            back.tap()
        }
        XCTAssertTrue(app.buttons["deviceNavigationLink"].isHittable)
    }

    @MainActor
    func openSettings(in app: XCUIApplication) {
        if app.buttons["modelSettingsButton"].isHittable { return }
        returnToAssistant(in: app)
        openSidebar(in: app)
        app.buttons["sidebarSettingsButton"].tap()
        XCTAssertTrue(app.buttons["modelSettingsButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func openDevice(in app: XCUIApplication) {
        returnToAssistant(in: app)
        app.buttons["deviceNavigationLink"].tap()
        XCTAssertTrue(app.navigationBars["设备"].waitForExistence(timeout: 5)
                      || app.navigationBars["Device"].exists)
    }
}
