import Foundation
import XCTest
@testable import Eiscue

final class BackgroundTaskStatusTests: XCTestCase {
    func testLatestPendingStatusKeepsProgressAndTextTogether() {
        var status = BackgroundTaskStatus(title: "Pairing", subtitle: "Preparing", totalUnitCount: 4)

        XCTAssertTrue(status.update(completedUnitCount: 1, totalUnitCount: 4,
                                    title: nil, subtitle: "Waiting for confirmation"))
        XCTAssertTrue(status.update(completedUnitCount: 3, totalUnitCount: 5,
                                    title: "Connecting", subtitle: nil))

        XCTAssertEqual(status.title, "Connecting")
        XCTAssertEqual(status.subtitle, "Waiting for confirmation")
        XCTAssertEqual(status.completedUnitCount, 3)
        XCTAssertEqual(status.totalUnitCount, 5)
    }

    func testBlankSubtitleAlwaysUsesLocalizedFallback() {
        let fallback = String(localized: "background.status.running", defaultValue: "Task in progress", table: "BackgroundStatus")
        var status = BackgroundTaskStatus(title: "Working", subtitle: " \n\t", totalUnitCount: 1)
        XCTAssertEqual(status.subtitle, fallback)

        XCTAssertTrue(status.update(completedUnitCount: 0, totalUnitCount: 1,
                                    title: nil, subtitle: "Current step"))
        XCTAssertTrue(status.update(completedUnitCount: 0, totalUnitCount: 1,
                                    title: nil, subtitle: " \n"))
        XCTAssertEqual(status.subtitle, fallback)
    }

    func testInvalidProgressCannotReplaceLastAcceptedStatus() {
        let initial = BackgroundTaskStatus(title: "Working", subtitle: "Preparing", totalUnitCount: 4)
        for (completed, total): (Int64, Int64) in [(-1, 4), (0, 0), (5, 4)] {
            var status = initial
            XCTAssertFalse(status.update(completedUnitCount: completed, totalUnitCount: total,
                                         title: "Invalid", subtitle: "Invalid"))
            XCTAssertEqual(status, initial)
        }
    }

    func testPairingPhasesAdvanceOnlyWhenRealMilestonesArrive() {
        let phases = PairingStatusPresentation.allCases
        XCTAssertEqual(phases.map(\.completedWorkUnits), [0, 1, 2, 3, 4])
        XCTAssertEqual(phases.last?.completedWorkUnits, PairingStatusPresentation.totalWorkUnits)
        for phase in phases {
            XCTAssertFalse(phase.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(phase.subtitle.contains(where: \.isNumber), "Pairing codes must never enter activity text.")
        }
    }
}
