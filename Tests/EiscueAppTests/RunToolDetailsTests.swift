import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

final class RunToolDetailsTests: XCTestCase {
    func testActionUsesExactEarlierFrameIncludingPreviousActionResult() throws {
        let firstFrame = UUID(), nextFrame = UUID(), afterFrame = UUID()
        let observation = result(id: "screen", frame: firstFrame)
        let firstTap = result(id: "tap-one", name: "device_tap", frame: nextFrame)
        var secondTap = result(id: "tap-two", name: "device_tap", frame: afterFrame)
        secondTap = ToolActivity(id: secondTap.id, name: secondTap.name, endedAt: Date(),
                                 arguments: #"{"frameId":"\#(nextFrame.uuidString.lowercased())","x":24,"y":80}"#,
                                 output: secondTap.output)
        let details = RunToolDetails(activity: secondTap, activities: [observation, firstTap, secondTap])
        XCTAssertEqual(details.sourceActivity?.id, firstTap.id)
        XCTAssertEqual(details.sourceFrame?.id, nextFrame)
        XCTAssertEqual(details.outputFrame?.id, afterFrame)
        XCTAssertEqual(details.imageMarker, .tap(.init(x: 24, y: 80)))
    }

    func testMissingFrameNeverFallsBackToCurrentOrLaterImage() {
        let missingFrame = UUID()
        let tap = ToolActivity(id: "tap", name: "device_tap", endedAt: Date(),
                               arguments: #"{"frameId":"\#(missingFrame)","x":12,"y":32}"#,
                               output: result(id: "unused", frame: missingFrame).output)
        let details = RunToolDetails(activity: tap, activities: [result(id: "other", frame: UUID()), tap,
                                                               result(id: "later", frame: missingFrame)])
        XCTAssertNil(details.sourceActivity)
        XCTAssertNil(details.imageMarker)
        XCTAssertEqual(details.marker, .tap(.init(x: 12, y: 32)), "Coordinates remain inspectable even when the matching screen is missing.")
    }

    func testMarkersRejectOutOfBoundsCoordinatesAndFailedFrameSources() {
        let frameID = UUID()
        let source = result(id: "screen", frame: frameID)
        let swipe = ToolActivity(id: "swipe", name: "device_swipe", endedAt: Date(),
                                 arguments: #"{"frameId":"\#(frameID)","fromX":12,"fromY":32,"toX":101,"toY":400}"#)
        let details = RunToolDetails(activity: swipe, activities: [source, swipe])
        XCTAssertNotNil(details.marker)
        XCTAssertNil(details.imageMarker, "Do not draw an invented in-bounds position by clamping the requested input.")
        var failed = source
        failed.isError = true
        XCTAssertNil(RunToolDetails(activity: swipe, activities: [failed, swipe]).sourceActivity)
    }

    func testExportRemainsMetadataOnlyWhenDetailedActivitiesExist() {
        let privateInput = "PRIVATE_TYPED_TEXT"
        let privateOutput = "PRIVATE_OUTPUT_WITH_SCREEN_DATA"
        let activity = ToolActivity(id: "call", name: "device_type_text", endedAt: Date(),
                                    arguments: #"{"text":"\#(privateInput)"}"#, output: privateOutput)
        let run = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(),
                            scope: .control, model: "fixture-model", skill: nil, state: .completed,
                            endedAt: Date(), detail: privateOutput,
                            events: [RunLogEntry(kind: "tool.finished", summary: "device_type_text"),
                                     RunLogEntry(kind: "other", summary: privateOutput)],
                            activities: [activity])
        let report = RunReport.text(run)
        XCTAssertFalse(report.contains(privateInput))
        XCTAssertFalse(report.contains(privateOutput))
        XCTAssertFalse(report.contains(activity.arguments))
        XCTAssertTrue(report.contains("fixture-model"))
    }

    func testTimelineInterleavesStepsAndLogsWithoutDroppingEither() {
        let event = RunLogEntry(kind: "tool.finished", summary: "device_tap")
        let before = ToolActivity(id: "before", name: "device_tap", startedAt: event.date.addingTimeInterval(-1))
        let after = ToolActivity(id: "after", name: "device_screenshot", startedAt: event.date.addingTimeInterval(1))
        let run = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: event.date,
                            scope: .control, model: "fixture", skill: nil, state: .completed, detail: "",
                            events: [event], activities: [after, before])
        XCTAssertEqual(run.timeline.map(\.id), ["activity:before", "event:\(event.id)", "activity:after"])
    }

    private func result(id: String, name: String = "device_screenshot", frame: UUID) -> ToolActivity {
        ToolActivity(id: id, name: name, endedAt: Date(),
                     output: "Action submitted. frameId=\(frame.uuidString); width=100; height=200; capturedAt=2026-10-14T10:00:00Z.")
    }
}
