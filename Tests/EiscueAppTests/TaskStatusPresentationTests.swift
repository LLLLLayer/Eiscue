import Foundation
import XCTest
@testable import Eiscue

final class TaskStatusPresentationTests: XCTestCase {
    func testNeverPublishesJournalDetailsModelSkillOrUnknownToolText() {
        let secret = "PRIVATE-user-prompt-model-response-api-key"
        let events = [RunLogEntry(kind: "tool.started", summary: secret),
                      RunLogEntry(kind: "tool.error", summary: secret)]
        let run = makeRun(.running, events: events, privateText: secret)

        for currentTool in [secret, "device_tap\n\(secret)", "device_\(secret)"] {
            let snapshot = TaskStatusPresentation.snapshot(for: run, currentTool: currentTool, isReceivingResponse: true)
            XCTAssertEqual(snapshot.title, localized("task.status.title.executing", "Running a step"))
            XCTAssertEqual(snapshot.subtitle, localized("task.status.operation.other", "Performing the next step"))
            XCTAssertFalse(snapshot.title.contains(secret))
            XCTAssertFalse(snapshot.subtitle.contains(secret))
        }
    }

    func testOnlyExactKnownToolNamesHaveSpecificOperationLabels() {
        let expected: [(String, StaticString, String.LocalizationValue)] = [
            ("device_screenshot", "task.status.operation.screenshot", "Reading the current screen"),
            ("device_tap", "task.status.operation.tap", "Tapping the screen"),
            ("device_swipe", "task.status.operation.swipe", "Swiping the screen"),
            ("device_type_text", "task.status.operation.type-text", "Entering text"),
            ("device_press_key", "task.status.operation.press-key", "Using the keyboard"),
            ("device_launch_app", "task.status.operation.launch-app", "Opening an app"),
            ("device_home", "task.status.operation.home", "Returning to the Home Screen"),
            ("device_list_apps", "task.status.operation.list-apps", "Finding apps")
        ]
        for (tool, key, fallback) in expected {
            let snapshot = TaskStatusPresentation.snapshot(for: makeRun(.running), currentTool: tool)
            XCTAssertEqual(snapshot.subtitle, localized(key, fallback))
            XCTAssertFalse(snapshot.subtitle.contains(tool))
        }
    }

    func testRunnerVerificationOverridesActionWithoutInventingToolCalls() {
        let run = makeRun(.running, events: [event("run.started"), event("tool.started"), event("action.acknowledged")])
        for phase in [DeviceTaskPhase.observing, .verifying] {
            let snapshot = TaskStatusPresentation.snapshot(for: run, currentTool: "device_tap", devicePhase: phase)
            if phase == .verifying {
                XCTAssertEqual(snapshot.title, localized("task.status.title.verifying", "Checking result"))
                XCTAssertEqual(snapshot.subtitle, localized("task.status.phase.verifying", "Checking the screen after the action"))
            } else {
                XCTAssertEqual(snapshot.title, localized("task.status.title.observing", "Viewing screen"))
                XCTAssertEqual(snapshot.subtitle, localized("task.status.operation.screenshot", "Reading the current screen"))
            }
            XCTAssertEqual(snapshot.completedToolCalls, 0)
            XCTAssertEqual(snapshot.completedWorkUnits, 1)
            XCTAssertEqual(snapshot.totalWorkUnits, 3, "Internal observations are not separate Pi tool calls.")
        }
        let deciding = TaskStatusPresentation.snapshot(for: run, currentTool: "device_tap", devicePhase: .deciding)
        XCTAssertEqual(deciding.title, localized("task.status.title.waiting", "Waiting for AI"))
        XCTAssertEqual(deciding.subtitle, localized("task.status.phase.waiting", "Waiting for the next response"))
        let receiving = TaskStatusPresentation.snapshot(for: run, currentTool: "device_tap", isReceivingResponse: true, devicePhase: .deciding)
        XCTAssertEqual(receiving.title, localized("task.status.title.responding", "Receiving a reply"))
        XCTAssertEqual(receiving.subtitle, localized("task.status.phase.analyzing", "Receiving and preparing the response"))
        let executing = TaskStatusPresentation.snapshot(for: run, currentTool: "device_tap", devicePhase: .executing)
        XCTAssertEqual(executing.subtitle, localized("task.status.operation.tap", "Tapping the screen"))
    }

    func testFinalizationAndTerminalStateOverrideStaleRunnerPhase() {
        let finishing = TaskStatusPresentation.snapshot(for: makeRun(.running), currentTool: "device_tap",
                                                        isFinishing: true, devicePhase: .verifying)
        XCTAssertEqual(finishing.title, localized("task.status.title.finishing", "Finishing up"))
        XCTAssertEqual(finishing.subtitle, localized("task.status.phase.finishing", "Saving results and releasing the device"))
        let cases: [(RunState, StaticString, String.LocalizationValue)] = [
            (.completed, "task.status.phase.completed", "Open Eiscue to view the result"),
            (.paused, "task.status.phase.paused", "Open Eiscue to continue"),
            (.interrupted, "task.status.phase.interrupted", "Open Eiscue to review the task"),
            (.failed, "task.status.phase.failed", "Open Eiscue to see what happened")
        ]
        for (state, key, fallback) in cases {
            let snapshot = TaskStatusPresentation.snapshot(for: makeRun(state), currentTool: "device_tap",
                                                           isFinishing: true, devicePhase: .verifying)
            XCTAssertEqual(snapshot.subtitle, localized(key, fallback))
        }
    }

    func testPrimaryTitleNeverClaimsRunningAfterTerminalOrRunnerStop() {
        let cases: [(RunState, StaticString, String.LocalizationValue)] = [
            (.completed, "task.status.title.completed", "Turn ended"),
            (.paused, "task.status.title.paused", "Task paused"),
            (.interrupted, "task.status.title.interrupted", "Task stopped"),
            (.failed, "task.status.title.failed", "Task failed")
        ]
        for (state, key, fallback) in cases {
            let status = TaskStatusPresentation.snapshot(for: makeRun(state), currentTool: "device_tap",
                                                        isReceivingResponse: true, devicePhase: .executing)
            XCTAssertEqual(status.title, localized(key, fallback))
        }
        let paused = TaskStatusPresentation.snapshot(for: makeRun(.running), devicePhase: .paused)
        XCTAssertEqual(paused.title, localized("task.status.title.paused", "Task paused"))
        let stopped = TaskStatusPresentation.snapshot(for: makeRun(.running), devicePhase: .stopped)
        XCTAssertEqual(stopped.title, localized("task.status.title.interrupted", "Task stopped"))
    }

    func testPreparationModelResponseAndFinalizationAdvanceOnlyAtRealBoundaries() {
        var run = makeRun(.preparing)
        var snapshot = TaskStatusPresentation.snapshot(for: run)
        XCTAssertEqual(snapshot.subtitle, localized("task.status.phase.preparing", "Preparing device and background access"))
        XCTAssertEqual(snapshot.completedWorkUnits, 0)
        XCTAssertEqual(snapshot.totalWorkUnits, 2)

        run.state = .running
        run.events.append(RunLogEntry(kind: "run.started", summary: "private"))
        snapshot = TaskStatusPresentation.snapshot(for: run)
        XCTAssertEqual(snapshot.subtitle, localized("task.status.phase.waiting", "Waiting for the next response"))
        XCTAssertEqual(snapshot.completedWorkUnits, 1)

        let receiving = TaskStatusPresentation.snapshot(for: run, isReceivingResponse: true)
        XCTAssertEqual(receiving.subtitle, localized("task.status.phase.analyzing", "Receiving and preparing the response"))
        XCTAssertEqual(receiving.completedWorkUnits, snapshot.completedWorkUnits)
        XCTAssertEqual(receiving.totalWorkUnits, snapshot.totalWorkUnits)

        let finishing = TaskStatusPresentation.snapshot(for: run, currentTool: "device_tap", isFinishing: true)
        XCTAssertEqual(finishing.subtitle, localized("task.status.phase.finishing", "Saving results and releasing the device"))
        XCTAssertEqual(finishing.completedWorkUnits, 1, "Starting cleanup does not mean cleanup has finished.")

        run.state = .completed
        let completed = TaskStatusPresentation.snapshot(for: run)
        XCTAssertEqual(completed.subtitle, localized("task.status.phase.completed", "Open Eiscue to view the result"))
        XCTAssertEqual(completed.completedWorkUnits, 2)
        XCTAssertEqual(completed.totalWorkUnits, 2)
    }

    func testSuccessfulAndFailedCallsCountAsEndedButNotAsGoalSuccess() {
        var run = makeRun(.running)
        run.events = [event("run.started"), event("tool.started")]
        var snapshot = TaskStatusPresentation.snapshot(for: run)
        XCTAssertEqual(snapshot.completedToolCalls, 0)
        XCTAssertEqual(snapshot.completedWorkUnits, 1)
        XCTAssertEqual(snapshot.totalWorkUnits, 3)

        run.events += [event("action.acknowledged"), event("tool.finished"),
                       event("tool.started"), event("tool.failed"), event("tool.error")]
        snapshot = TaskStatusPresentation.snapshot(for: run)
        XCTAssertEqual(snapshot.completedToolCalls, 2)
        XCTAssertEqual(snapshot.completedWorkUnits, 3)
        XCTAssertEqual(snapshot.totalWorkUnits, 4)
        XCTAssertEqual(snapshot.subtitle, localized("task.status.phase.waiting", "Waiting for the next response"))
    }

    func testRepeatedJournalEntryDoesNotInventWorkButDistinctCallsToSameToolCount() {
        let started = event("tool.started")
        let ended = event("tool.finished")
        var run = makeRun(.running)
        run.events = [started, ended, started, ended]
        let replayed = TaskStatusPresentation.snapshot(for: run)
        XCTAssertEqual(replayed.completedToolCalls, 1)
        XCTAssertEqual(replayed.totalWorkUnits, 3)

        run.events += [event("tool.started"), event("tool.finished")]
        let newInvocation = TaskStatusPresentation.snapshot(for: run)
        XCTAssertEqual(newInvocation.completedToolCalls, 2)
        XCTAssertEqual(newInvocation.totalWorkUnits, 4)
    }

    func testRecoveredCompletionIsEvidenceOfOneDiscoveredCall() {
        let run = makeRun(.running, events: [event("tool.finished")])
        let snapshot = TaskStatusPresentation.snapshot(for: run)
        XCTAssertEqual(snapshot.completedToolCalls, 1)
        XCTAssertEqual(snapshot.completedWorkUnits, 2)
        XCTAssertEqual(snapshot.totalWorkUnits, 3)
    }

    func testTerminalFailureAndInterruptionOverrideStaleToolAndDoNotFillProgress() {
        let cases: [(RunState, StaticString, String.LocalizationValue)] = [
            (.paused, "task.status.phase.paused", "Open Eiscue to continue"),
            (.interrupted, "task.status.phase.interrupted", "Open Eiscue to review the task"),
            (.failed, "task.status.phase.failed", "Open Eiscue to see what happened")
        ]
        for (state, key, fallback) in cases {
            var run = makeRun(state)
            var snapshot = TaskStatusPresentation.snapshot(for: run, currentTool: "device_tap", isReceivingResponse: true, isFinishing: true)
            XCTAssertEqual(snapshot.subtitle, localized(key, fallback))
            XCTAssertEqual(snapshot.completedWorkUnits, 0, "A failure before preparation finished must remain at zero.")
            XCTAssertEqual(snapshot.totalWorkUnits, 2)

            run.events = [event("run.started"), event("tool.started")]
            snapshot = TaskStatusPresentation.snapshot(for: run)
            XCTAssertEqual(snapshot.completedWorkUnits, 1)
            XCTAssertEqual(snapshot.totalWorkUnits, 3)
        }
    }

    func testPausedStatusKeepsObservedProgressWithoutClaimingCompletion() throws {
        var run = makeRun(.paused, events: [event("run.started"), event("tool.started"), event("tool.finished")])
        run.pauseReason = .toolLimit
        let status = TaskStatusPresentation.snapshot(for: run, currentTool: "device_tap", isFinishing: true)
        XCTAssertEqual(status.title, localized("task.status.title.paused", "Task paused"))
        XCTAssertEqual(status.subtitle, localized("task.status.phase.paused", "Open Eiscue to continue"))
        XCTAssertEqual(status.completedToolCalls, 1)
        XCTAssertEqual(status.completedWorkUnits, 2)
        XCTAssertEqual(status.totalWorkUnits, 3)

        for reason in [RunPauseReason.toolLimit, .noProgress] {
            run.pauseReason = reason
            let restored = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(run))
            XCTAssertEqual(restored.state, .paused)
            XCTAssertEqual(restored.pauseReason, reason)
        }
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        legacy.removeValue(forKey: "pauseReason")
        legacy["state"] = "interrupted"
        let restoredLegacy = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restoredLegacy.state, .interrupted)
        XCTAssertNil(restoredLegacy.pauseReason, "Existing journals remain readable without the new optional field.")
    }

    func testModelTokensPrivateMetadataAndElapsedTimeCannotFabricateProgress() {
        var run = makeRun(.running, events: [event("run.started")])
        let before = TaskStatusPresentation.snapshot(for: run, isReceivingResponse: true)
        run.detail = "Changed model content and task budget: 999999"
        run.endedAt = Date.distantFuture
        run.events += [event("assistant.text"), event("assistant.text"), event("action.acknowledged")]
        let after = TaskStatusPresentation.snapshot(for: run, isReceivingResponse: true)
        XCTAssertEqual(before, after, "Identical snapshots can be cached without refreshing every streamed token.")
        XCTAssertEqual(after.completedWorkUnits, 1)
        XCTAssertEqual(after.totalWorkUnits, 2)
    }

    private func localized(_ key: StaticString, _ fallback: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: fallback, table: "TaskStatus")
    }

    private func event(_ kind: String) -> RunLogEntry {
        RunLogEntry(kind: kind, summary: "device_tap")
    }

    private func makeRun(_ state: RunState, events: [RunLogEntry] = [], privateText: String = "private") -> RunRecord {
        RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: .distantPast,
                  scope: .control, model: privateText, skill: privateText, state: state,
                  detail: privateText, events: events)
    }
}
