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

    @MainActor
    func testRunnerStopKeepsHostFinalizingUntilCleanupAndJournalSaveFinish() throws {
        let suite = "eiscue.background-tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(storageDirectory: directory, preferences: preferences)
        let runID = UUID()
        model.activeRun = RunRecord(id: runID, conversationID: UUID(), requestID: UUID(), startedAt: .now,
                                    scope: .control, model: "fixture", skill: nil, state: .completed,
                                    detail: "", events: [RunLogEntry(kind: "run.started", summary: "")])
        var callbacks: [TaskStatusPresentation] = []
        model.deviceTools = DeviceToolSession(capabilities: [], client: model.deviceClient, scope: .control,
                                             timeoutSeconds: 30, log: { _, _ in }, onUnknown: {},
                                             onPhaseChanged: { [weak model] _ in
                                                 if let status = model?.taskStatusPresentation() { callbacks.append(status) }
                                             })

        // This is the synchronous stop callback before DeviceRunCleanup runs.
        model.companionFinalizingRunID = runID
        model.deviceTools?.stop()
        // endedAt is assigned before the asynchronous journal save finishes.
        model.activeRun?.endedAt = .now
        model.deviceTools?.stop()
        XCTAssertEqual(callbacks.count, 2)
        for status in callbacks {
            XCTAssertEqual(status.title, String(localized: "task.status.title.finishing", defaultValue: "Finishing up", table: "TaskStatus"))
            XCTAssertLessThan(status.completedWorkUnits, status.totalWorkUnits)
        }
        XCTAssertEqual(model.activeRun?.state, .completed, "Presentation must not overwrite the journal's outcome.")

        model.companionFinalizingRunID = nil
        model.deviceTools?.stop()
        let completed = try XCTUnwrap(callbacks.last)
        XCTAssertEqual(callbacks.count, 3)
        XCTAssertEqual(completed.title, String(localized: "task.status.title.completed", defaultValue: "Turn ended", table: "TaskStatus"))
        XCTAssertEqual(completed.completedWorkUnits, completed.totalWorkUnits)
    }
}
