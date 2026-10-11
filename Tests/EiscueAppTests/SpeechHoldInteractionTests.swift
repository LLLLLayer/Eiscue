import XCTest
@testable import Eiscue

final class SpeechHoldInteractionTests: XCTestCase {
    func testPressReleaseAndSystemCancellationAreAtMostOnce() {
        var hold = SpeechHoldInteraction()
        XCTAssertTrue(hold.begin(isEnabled: true))
        XCTAssertFalse(hold.begin(isEnabled: true))
        XCTAssertEqual(hold.end(), .finish)
        XCTAssertNil(hold.end())
        XCTAssertTrue(hold.begin(isEnabled: true))
        XCTAssertEqual(hold.end(cancelled: true), .cancel)
        XCTAssertFalse(hold.isPressed)
    }
    func testSlideUpCancelsAndSlidingBackAllowsCompletion() {
        var hold = SpeechHoldInteraction()
        XCTAssertTrue(hold.begin(isEnabled: true))
        hold.move(verticalDistance: -80)
        XCTAssertTrue(hold.isCancelling)
        XCTAssertEqual(hold.end(), .cancel)
        XCTAssertTrue(hold.begin(isEnabled: true))
        hold.move(verticalDistance: -90)
        hold.move(verticalDistance: -20)
        XCTAssertFalse(hold.isCancelling)
        XCTAssertEqual(hold.end(), .finish)
    }
    func testDisabledPressCannotStartOrCommit() {
        var hold = SpeechHoldInteraction()
        XCTAssertFalse(hold.begin(isEnabled: false))
        hold.move(verticalDistance: -80)
        XCTAssertNil(hold.end())
    }
}
