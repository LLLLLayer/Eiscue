import EiscueDeviceKit
import XCTest
@testable import Eiscue

final class BoardCompanionPresentationTests: XCTestCase {
    func testOnlySuccessfulUniqueToolEndingsCountAsSteps() {
        let done = RunLogEntry(kind: "tool.finished", summary: "private tool arguments")
        var run = makeRun()
        run.events = [done, done, RunLogEntry(kind: "action.acknowledged", summary: "private screenshot"),
                      RunLogEntry(kind: "tool.failed", summary: "private failure")]
        let value = BoardCompanionPresentation.task(run, currentTool: "device_tap\nprivate prompt",
                                                   stopping: false, finishing: false, language: .english)
        XCTAssertEqual(value.completedActions, 1)
        XCTAssertEqual(value.phase, .waiting, "Untrusted tool names cannot become specific board instructions.")
        run.events.append(RunLogEntry(kind: "tool.finished", summary: "same operation, different invocation"))
        XCTAssertEqual(BoardCompanionPresentation.task(run, currentTool: "", stopping: false,
                                                       finishing: false, language: .english).completedActions, 2)
    }

    func testTurnEndWaitsForCleanupAndDurableFinalization() {
        var run = makeRun()
        run.state = .completed
        XCTAssertEqual(BoardCompanionPresentation.task(run, currentTool: "", stopping: false,
                                                       finishing: false, language: .english).phase, .waiting)
        run.endedAt = Date()
        XCTAssertEqual(BoardCompanionPresentation.task(run, currentTool: "", stopping: false,
                                                       finishing: true, language: .english).phase, .waiting)
        XCTAssertEqual(BoardCompanionPresentation.task(run, currentTool: "", stopping: false,
                                                       finishing: false, language: .english).phase, .completed)
    }

    func testStopOverridesStaleToolAndReadiness() {
        let run = makeRun()
        XCTAssertEqual(BoardCompanionPresentation.task(run, currentTool: "device_tap", stopping: true,
                                                       finishing: true, language: .english).phase, .stopped)
        XCTAssertEqual(BoardCompanionPresentation.setup(connected: true, sharing: true, ready: true,
                                                        stopped: true, language: .english).phase, .stopped)
        XCTAssertEqual(BoardCompanionPresentation.setup(connected: true, sharing: false, ready: true,
                                                        stopped: false, language: .english).phase, .needsScreenSharing)
    }

    func testPauseUsesWaitingPhaseInsteadOfShowingExecutionOrSuccess() {
        var run = makeRun()
        run.state = .paused; run.pauseReason = .toolLimit; run.endedAt = Date()
        XCTAssertEqual(BoardCompanionPresentation.task(run, currentTool: "device_tap", stopping: false,
                                                       finishing: false, language: .english).phase, .waiting)
    }

    private func makeRun() -> RunRecord {
        RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(), scope: .chat,
                  model: "private-model", skill: "private-skill", state: .running, detail: "private-response", events: [])
    }
}
