import XCTest

final class MascotGalleryUITests: XCTestCase {
    @MainActor
    func testHeadStylesPreviewConnectionStatesInBothAppearances() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 10))
        for appearance in ["Light", "Dark"] {
            openSettings(in: app)
            app.buttons["appearancePicker"].tap()
            app.buttons[appearance].tap()
            app.buttons["stickerGalleryNavigationLink"].tap()
            let states = app.segmentedControls["mascotPreviewState"]
            XCTAssertTrue(states.waitForExistence(timeout: 5))
            for state in ["Disconnected", "Ready", "Connecting"] {
                states.buttons[state].tap()
                for style in ["ice", "ink", "pixel"] {
                    let face = app.descendants(matching: .any)["mascotPreview_\(style)"].firstMatch
                    XCTAssertTrue(face.exists)
                    XCTAssertEqual(face.value as? String, state)
                }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Head styles — \(state), \(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            returnToAssistant(in: app)
        }
    }
}
