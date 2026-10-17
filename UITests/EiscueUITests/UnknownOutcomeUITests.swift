import XCTest

final class UnknownOutcomeUITests: XCTestCase {
    @MainActor func testUnknownOutcomeOffersOnlyConfirmationAndEndAndRequiresReconnection() {
        let app = launch()
        let card = app.descendants(matching: .any)["unknownRunStatus"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Action result unconfirmed"].exists)
        XCTAssertTrue(app.buttons["confirmUnknownRunButton"].exists)
        XCTAssertTrue(app.buttons["endUnknownRunButton"].exists)
        XCTAssertEqual(card.descendants(matching: .button).count, 2)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        XCTAssertFalse(app.buttons["continuePausedRunButton"].exists)
        app.buttons["confirmUnknownRunButton"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Reconnect the device, then continue the task."].exists)
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(card.exists)
        XCTAssertTrue(app.buttons["confirmUnknownRunButton"].exists)
    }

    @MainActor func testEndingUnknownOutcomeDismissesItsContinuationCard() {
        let app = launch()
        let card = app.descendants(matching: .any)["unknownRunStatus"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        app.buttons["endUnknownRunButton"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["confirmUnknownRunButton"].exists)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "--unknown-outcome-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }
}
