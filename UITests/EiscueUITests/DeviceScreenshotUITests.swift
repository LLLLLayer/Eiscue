import XCTest

/// Explicit observation only: retain the installed app, its data and current page.
final class DeviceScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Current-device capture requires an explicitly selected physical device.")
        #else
        guard ProcessInfo.processInfo.environment["EISCUE_DEVICE_SCREENSHOT"] == "1" else {
            throw XCTSkip("Run explicitly with TEST_RUNNER_EISCUE_DEVICE_SCREENSHOT=1.")
        }
        #endif
    }

    @MainActor
    func testCaptureCurrentPage() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        guard app.state != .notRunning else {
            throw XCTSkip("Open Eiscue to the page being inspected first; this test does not relaunch it.")
        }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Eiscue-current-device-page"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
