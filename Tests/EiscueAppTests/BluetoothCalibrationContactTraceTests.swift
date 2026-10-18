import EiscueDeviceCore
import UIKit
import XCTest
@testable import Eiscue

final class BluetoothCalibrationContactTraceTests: XCTestCase {
    func testContinuousContactRecordsActualDisplacementAndReceipt() throws {
        var trace = BluetoothCalibrationContactTrace()
        let start = DevicePoint(x: 0.35, y: 0.35), end = DevicePoint(x: 0.55, y: 0.36)
        trace.record(id: 1, phase: .began, point: start, uptime: 10)
        XCTAssertNil(trace.observation(probe: .horizontalLarge, receipt: UUID()))
        trace.record(id: 1, phase: .moved, point: end, uptime: 10.1)
        trace.record(id: 1, phase: .ended, point: end, uptime: 10.2)
        let receipt = UUID()
        let observation = try XCTUnwrap(trace.observation(probe: .horizontalLarge, receipt: receipt))
        XCTAssertEqual(observation.receiptToken, receipt)
        XCTAssertEqual(observation.start, start)
        XCTAssertEqual(observation.end, end)
        XCTAssertEqual(observation.contactCount, 1)
        XCTAssertEqual(observation.movedEventCount, 1)
        XCTAssertTrue(observation.endedNormally)
        XCTAssertEqual(observation.startedUptime, 10)
        XCTAssertEqual(observation.endedUptime, 10.2)
    }

    func testBrokenTouchAndCancellationRemainVisibleToCoreValidation() throws {
        var trace = BluetoothCalibrationContactTrace()
        let point = DevicePoint(x: 0.35, y: 0.35)
        trace.record(id: 1, phase: .began, point: point, uptime: 10)
        trace.record(id: 1, phase: .ended, point: point, uptime: 10.02)
        trace.record(id: 2, phase: .began, point: point, uptime: 10)
        trace.record(id: 2, phase: .moved, point: DevicePoint(x: 0.5, y: 0.35), uptime: 10.1)
        let broken = try XCTUnwrap(trace.observation(probe: .horizontalLarge, receipt: UUID()))
        XCTAssertEqual(broken.contactCount, 2)
        XCTAssertEqual(broken.movedEventCount, 0)
        XCTAssertEqual(broken.end, point)

        var cancelled = BluetoothCalibrationContactTrace()
        cancelled.record(id: 1, phase: .began, point: point, uptime: 10)
        cancelled.record(id: 1, phase: .moved, point: DevicePoint(x: 0.5, y: 0.35), uptime: 10.1)
        cancelled.record(id: 1, phase: .cancelled, point: point, uptime: 10.2)
        XCTAssertFalse(try XCTUnwrap(cancelled.observation(probe: .horizontalLarge, receipt: UUID())).endedNormally)
    }

    func testEmptyAttemptReportsCompletedCommandWithoutUIKitContact() throws {
        let trace = BluetoothCalibrationContactTrace()
        let report = trace.diagnostic(probe: .horizontalSmall, commandCompleted: true)

        XCTAssertEqual(report["probe"] as? String, "horizontalSmall")
        XCTAssertEqual(report["commandCompleted"] as? Bool, true)
        XCTAssertEqual(report["failureReason"] as? String, "contactMissing")
        XCTAssertEqual(report["contacts"] as? Int, 0)
        XCTAssertEqual(report["receivedEvents"] as? Int, 0)
        XCTAssertEqual(report["hasBegan"] as? Bool, false)
        XCTAssertEqual(report["hasTerminated"] as? Bool, false)
        XCTAssertTrue(report["start"] is NSNull)
        XCTAssertTrue(report["end"] is NSNull)
        XCTAssertTrue(report["contactDuration"] is NSNull)
        XCTAssertNil(trace.observation(probe: .horizontalSmall, receipt: UUID()))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: report))
    }

    func testIncompleteAttemptRetainsMovementWithoutAuthorizingObservation() throws {
        var trace = BluetoothCalibrationContactTrace()
        trace.record(id: 1, phase: .began, point: DevicePoint(x: 0.35, y: 0.35), uptime: 10)
        trace.record(id: 1, phase: .moved, point: DevicePoint(x: 0.5, y: 0.36), uptime: 10.1)
        let report = trace.diagnostic(probe: .horizontalSmall, commandCompleted: true)

        XCTAssertEqual(report["failureReason"] as? String, "contactIncomplete")
        XCTAssertEqual(report["contacts"] as? Int, 1)
        XCTAssertEqual(report["receivedEvents"] as? Int, 2)
        XCTAssertEqual(report["movedEvents"] as? Int, 1)
        XCTAssertEqual(report["hasBegan"] as? Bool, true)
        XCTAssertEqual(report["hasTerminated"] as? Bool, false)
        XCTAssertEqual(report["end"] as? [String: Double], ["x": 0.5, "y": 0.36])
        XCTAssertEqual(try XCTUnwrap(report["observedDuration"] as? Double), 0.1, accuracy: 0.0001)
        XCTAssertTrue(report["contactDuration"] is NSNull)
        XCTAssertNil(trace.observation(probe: .horizontalSmall, receipt: UUID()))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: report))
    }

    func testContactWithoutBeganIsDistinctFromNoContact() throws {
        var trace = BluetoothCalibrationContactTrace()
        trace.record(id: 1, phase: .ended, point: DevicePoint(x: 0.5, y: 0.35), uptime: 10)
        let report = trace.diagnostic(probe: .horizontalSmall, commandCompleted: true)

        XCTAssertEqual(report["failureReason"] as? String, "contactBeganMissing")
        XCTAssertEqual(report["contacts"] as? Int, 1)
        XCTAssertEqual(report["receivedEvents"] as? Int, 1)
        XCTAssertEqual(report["hasBegan"] as? Bool, false)
        XCTAssertEqual(report["hasTerminated"] as? Bool, false)
        XCTAssertNil(trace.observation(probe: .horizontalSmall, receipt: UUID()))
    }

    func testFailedProbeReportRetainsPartialTraceWithControlledReason() throws {
        var trace = BluetoothCalibrationContactTrace()
        trace.record(id: 1, phase: .began, point: DevicePoint(x: 0.35, y: 0.35), uptime: 10)
        let report = trace.diagnostic(probe: .horizontalSmall, commandCompleted: false,
                                      failureReason: .probeCommandFailed)

        XCTAssertEqual(report["failureReason"] as? String, "probeCommandFailed")
        XCTAssertEqual(report["commandCompleted"] as? Bool, false)
        XCTAssertEqual(report["contacts"] as? Int, 1)
        XCTAssertEqual(report["start"] as? [String: Double], ["x": 0.35, "y": 0.35])
        XCTAssertEqual(Set(report.keys), ["probe", "commandCompleted", "failureReason", "contacts", "receivedEvents",
            "movedEvents", "hasBegan", "hasTerminated", "endedNormally", "start", "end", "contactDuration", "observedDuration", "eventSummary"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: report))
    }

    func testNonFiniteTraceStatisticsRemainJSONSerializable() throws {
        var trace = BluetoothCalibrationContactTrace()
        trace.record(id: 1, phase: .began, point: DevicePoint(x: .nan, y: 0.35), uptime: 10)
        trace.record(id: 1, phase: .ended, point: DevicePoint(x: 0.35, y: .infinity), uptime: .infinity)
        let report = trace.diagnostic(probe: .horizontalSmall, commandCompleted: true)

        XCTAssertTrue(report["start"] is NSNull)
        XCTAssertTrue(report["end"] is NSNull)
        XCTAssertTrue(report["contactDuration"] is NSNull)
        XCTAssertTrue(report["observedDuration"] is NSNull)
        XCTAssertEqual(report["hasTerminated"] as? Bool, true)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: report))
    }

    func testOnlyPageContactsHittingTargetAuthorizeRelativeObservation() throws {
        var diagnostics = diagnosticsWithBaseline(types: Array(repeating: .indirectPointer, count: 4))
        XCTAssertEqual(diagnostics.selectedTouchType, .indirectPointer)
        diagnostics.beginRelative()
        for phase in [UITouch.Phase.began, .moved, .ended] {
            diagnostics.record(source: .page, id: 1, phase: phase, type: .indirectPointer,
                point: DevicePoint(x: 0.35, y: 0.35), uptime: 10, hitTarget: false)
            diagnostics.record(source: .legacyTarget, id: 2, phase: phase, type: .direct,
                point: DevicePoint(x: 0.35, y: 0.35), uptime: 10, hitTarget: true)
        }
        XCTAssertNil(diagnostics.relativeObservation(probe: .horizontalSmall, receipt: UUID()))
        XCTAssertNotNil(diagnostics.pageTrace.observation(probe: .horizontalSmall, receipt: UUID()))
        XCTAssertNotNil(diagnostics.legacyTargetTrace.observation(probe: .horizontalSmall, receipt: UUID()))

        diagnostics.beginRelative()
        for phase in [UITouch.Phase.began, .moved, .ended] {
            diagnostics.record(source: .page, id: 3, phase: phase, type: .indirectPointer,
                point: DevicePoint(x: 0.35, y: 0.35), uptime: 10, hitTarget: true)
            diagnostics.record(source: .legacyTarget, id: 4, phase: phase, type: .direct,
                point: DevicePoint(x: 0.35, y: 0.35), uptime: 10, hitTarget: true)
        }
        let observation = try XCTUnwrap(diagnostics.relativeObservation(probe: .horizontalSmall, receipt: UUID()))
        XCTAssertEqual(observation.contactCount, 1)
        XCTAssertEqual(observation.movedEventCount, 1)
        let report = diagnostics.relativeTrace.diagnostic(probe: .horizontalSmall, commandCompleted: true)
        XCTAssertEqual(report["receivedEvents"] as? Int, 3)
    }

    func testNonTargetContactRejectsOtherwiseCompleteTargetDrag() throws {
        for secondHitsTarget in [false, true] {
            var diagnostics = diagnosticsWithBaseline(types: Array(repeating: .direct, count: 4))
            diagnostics.beginRelative()
            diagnostics.record(source: .page, id: 1, phase: .began, type: .direct,
                point: DevicePoint(x: 0.35, y: 0.35), uptime: 10, hitTarget: true)
            diagnostics.record(source: .page, id: 2, phase: .began, type: .direct,
                point: DevicePoint(x: 0.8, y: 0.8), uptime: 10.01, hitTarget: secondHitsTarget)
            diagnostics.record(source: .page, id: 1, phase: .moved, type: .direct,
                point: DevicePoint(x: 0.55, y: 0.35), uptime: 10.1, hitTarget: true)
            diagnostics.record(source: .page, id: 1, phase: .ended, type: .direct,
                point: DevicePoint(x: 0.55, y: 0.35), uptime: 10.2, hitTarget: true)

            XCTAssertEqual(diagnostics.relativeTrace.contactCount, secondHitsTarget ? 2 : 1)
            XCTAssertEqual(diagnostics.selectedPageContactCount, 2)
            XCTAssertNil(diagnostics.relativeObservation(probe: .horizontalSmall, receipt: UUID()))
            XCTAssertEqual(diagnostics.relativeObservationFailureReason, .multipleContacts)
            let report = diagnostics.relativeTrace.diagnostic(probe: .horizontalSmall, commandCompleted: true,
                failureReason: diagnostics.relativeObservationFailureReason)
            XCTAssertEqual(report["failureReason"] as? String, "multipleContacts")
        }
    }

    func testAbsoluteDirectChannelCompletesDespiteUnterminatedPointerMirrorWithoutFallback() throws {
        var diagnostics = diagnosticsWithBaseline(types: Array(repeating: .direct, count: 4))
        diagnostics.beginRelative()
        for phase in [UITouch.Phase.began, .moved, .ended] {
            if phase != .ended {
                diagnostics.record(source: .page, id: 1, phase: phase, type: .indirectPointer,
                    point: DevicePoint(x: 0.35, y: 0.35), uptime: 10, hitTarget: true)
            }
            diagnostics.record(source: .page, id: 2, phase: phase, type: .direct,
                point: DevicePoint(x: 0.35, y: 0.35), uptime: 10, hitTarget: true)
        }
        XCTAssertEqual(diagnostics.selectedTouchTypeName, "direct")
        XCTAssertEqual(diagnostics.pageTrace.contactCount, 2)
        XCTAssertFalse(diagnostics.pageTrace.hasTerminated)
        XCTAssertEqual(diagnostics.selectedPageContactCount, 1)
        let observation = try XCTUnwrap(diagnostics.relativeObservation(probe: .horizontalSmall, receipt: UUID()))
        XCTAssertEqual(observation.contactCount, 1)
        XCTAssertEqual(observation.movedEventCount, 1)
        XCTAssertTrue(observation.endedNormally)

        diagnostics.beginRelative()
        for phase in [UITouch.Phase.began, .moved, .ended] {
            diagnostics.record(source: .page, id: 3, phase: phase, type: .indirectPointer,
                point: DevicePoint(x: 0.35, y: 0.35), uptime: 11, hitTarget: true)
        }
        XCTAssertEqual(diagnostics.selectedTouchType, .direct)
        XCTAssertNil(diagnostics.relativeObservation(probe: .horizontalLarge, receipt: UUID()))
        XCTAssertEqual(diagnostics.relativeObservationFailureReason, .contactMissing)
    }

    func testMissingIncompleteMixedUnsealedAndLegacyBaselinesCannotSelectChannel() {
        let direct = Array(repeating: UITouch.TouchType.direct, count: 4)
        let cases: [([UITouch.TouchType], BluetoothCalibrationTouchDiagnostics.Source, Bool, Bool)] = [
            ([], .page, true, true), (direct, .page, false, true),
            ([.direct, .indirectPointer, .direct, .indirectPointer], .page, true, true),
            (direct, .page, true, false), (direct, .legacyTarget, true, true)]
        for (types, source, complete, seal) in cases {
            var diagnostics = diagnosticsWithBaseline(types: types, source: source, complete: complete, seal: seal)
            XCTAssertNil(diagnostics.selectedTouchType)
            diagnostics.beginRelative()
            for phase in [UITouch.Phase.began, .moved, .ended] {
                diagnostics.record(source: .page, id: 10, phase: phase, type: .direct,
                    point: DevicePoint(x: 0.35, y: 0.35), uptime: 10, hitTarget: true)
            }
            XCTAssertNil(diagnostics.relativeObservation(probe: .horizontalSmall, receipt: UUID()))
            XCTAssertEqual(diagnostics.relativeObservationFailureReason, .touchChannelUnconfirmed)
        }
    }

    private func diagnosticsWithBaseline(types: [UITouch.TouchType],
                                         source: BluetoothCalibrationTouchDiagnostics.Source = .page,
                                         complete: Bool = true, seal: Bool = true) -> BluetoothCalibrationTouchDiagnostics {
        var diagnostics = BluetoothCalibrationTouchDiagnostics()
        diagnostics.beginAbsolute()
        for (id, type) in types.enumerated() {
            for phase in complete ? [UITouch.Phase.began, .ended] : [.began] {
                diagnostics.record(source: source, id: id, phase: phase, type: type,
                    point: DevicePoint(x: 0.25, y: 0.25), uptime: Double(id), hitTarget: true)
            }
        }
        diagnostics.endStage()
        if seal { diagnostics.sealAbsoluteBaseline() }
        return diagnostics
    }

    func testAbsoluteBaselineSeparatesSourcesAndIgnoresInactiveStages() throws {
        var diagnostics = BluetoothCalibrationTouchDiagnostics()
        func record(_ source: BluetoothCalibrationTouchDiagnostics.Source, id: Int, phase: UITouch.Phase) {
            diagnostics.record(source: source, id: id, phase: phase, type: .indirectPointer,
                point: DevicePoint(x: 0.25, y: 0.25), uptime: 10, hitTarget: true)
        }
        record(.page, id: 0, phase: .began)
        diagnostics.beginAbsolute()
        for id in 1...4 {
            for phase in [UITouch.Phase.began, .ended] {
                record(.page, id: id, phase: phase)
                record(.legacyTarget, id: id, phase: phase)
            }
        }
        diagnostics.endStage()
        record(.page, id: 5, phase: .began)
        for key in ["pageTrace", "targetTrace", "legacyTargetTrace"] {
            let summary = try XCTUnwrap(diagnostics.absoluteDiagnostic[key] as? [String: Any])
            XCTAssertEqual(summary["events"] as? Int, 8)
            XCTAssertEqual((summary["phases"] as? [String: Int])?["began"], 4)
            XCTAssertEqual((summary["types"] as? [String: Int])?["indirectPointer"], 8)
        }
        diagnostics.beginRelative()
        diagnostics.endStage()
        record(.page, id: 6, phase: .began)
        XCTAssertEqual(diagnostics.relativeTrace.incompleteReason, .contactMissing)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: diagnostics.absoluteDiagnostic))
    }

    func testTouchSummaryBoundsSamplesAndPreservesFinalPhaseAndTypeCounts() throws {
        var summary = BluetoothCalibrationTouchSummary()
        for index in 0..<100 {
            summary.record(phase: index == 99 ? .ended : .moved,
                type: index.isMultiple(of: 2) ? .direct : .indirectPointer,
                point: DevicePoint(x: Double(index) / 100, y: 0.35), hitTarget: index < 50)
        }
        let report = summary.diagnostic
        let samples = try XCTUnwrap(report["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, BluetoothCalibrationTouchSummary.sampleLimit)
        XCTAssertEqual(report["droppedSamples"] as? Int, 68)
        XCTAssertEqual(report["targetHitEvents"] as? Int, 50)
        XCTAssertEqual(report["types"] as? [String: Int], ["direct": 50, "indirectPointer": 50, "other": 0])
        XCTAssertEqual(samples.last?["phase"] as? String, "ended")
        XCTAssertEqual(samples.last?["x"] as? Double, 0.99)
        XCTAssertEqual(Set(try XCTUnwrap(samples.first).keys), ["type", "phase", "hitTarget", "x", "y"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: report))
    }

    @MainActor func testPageObserverDoesNotDelayCancelOrPreventInput() {
        let observer = BluetoothCalibrationPageTouchObserver(target: nil, action: nil)
        let other = UITapGestureRecognizer()
        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        XCTAssertFalse(observer.requiresExclusiveTouchType)
        XCTAssertFalse(observer.canPrevent(other))
        XCTAssertFalse(observer.canBePrevented(by: other))
        XCTAssertFalse(observer.isRecording)
        XCTAssertEqual(observer.state, .possible)
        XCTAssertTrue(observer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)))
        XCTAssertTrue(observer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)))
        XCTAssertFalse(BluetoothCalibrationPageTouchObserver.shouldFinish(
            endedTypes: [.indirectPointer], activeTypes: [.direct], selectedType: .direct))
        XCTAssertFalse(BluetoothCalibrationPageTouchObserver.shouldFinish(
            endedTypes: [.indirectPointer], activeTypes: [], selectedType: .direct))
        XCTAssertTrue(BluetoothCalibrationPageTouchObserver.shouldFinish(
            endedTypes: [.direct], activeTypes: [.indirectPointer], selectedType: .direct))
        XCTAssertFalse(BluetoothCalibrationPageTouchObserver.shouldFinish(
            endedTypes: [.direct], activeTypes: [.direct], selectedType: .direct))
        XCTAssertFalse(BluetoothCalibrationPageTouchObserver.shouldFinish(
            endedTypes: [.direct], activeTypes: [.indirectPointer], selectedType: nil))
    }
}
