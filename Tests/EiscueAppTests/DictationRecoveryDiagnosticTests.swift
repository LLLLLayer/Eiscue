import Foundation
import XCTest
@testable import Eiscue

#if DEBUG
@MainActor
final class DictationRecoveryDiagnosticTests: XCTestCase {
    func testTimingBoundariesRequireBothExplicitOptIns() throws {
        typealias Configuration = DictationRecoveryDiagnostic.Configuration
        XCTAssertNil(Configuration(arguments: []))
        XCTAssertNil(Configuration(arguments: ["--speech-diagnostics"]))
        XCTAssertNil(Configuration(arguments: ["--dictation-wait-before-release", "--dictation-wait-before-publish"]))
        XCTAssertNil(Configuration(arguments: ["--speech-diagnostics", "--ui-testing"]))
        let release = try XCTUnwrap(Configuration(arguments: ["--speech-diagnostics", "--dictation-wait-before-release"]))
        XCTAssertTrue(release.beforeRelease)
        XCTAssertFalse(release.beforePublish)
        let publish = try XCTUnwrap(Configuration(arguments: ["--speech-diagnostics", "--dictation-wait-before-publish"]))
        XCTAssertFalse(publish.beforeRelease)
        XCTAssertTrue(publish.beforePublish)
    }

    func testEvidenceIsBoundedAndLateOldCallbacksCannotReplaceCurrentReport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostic.json")
        let configuration = try XCTUnwrap(DictationRecoveryDiagnostic.Configuration(
            arguments: ["--speech-diagnostics", "--dictation-wait-before-release"]))
        let old = DictationRecoveryDiagnostic(configuration: configuration, outputURL: url)
        for _ in 0..<80 { old.record(.releaseDispatched) }
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(initial.keys), ["schemaVersion", "releaseBeforeDispatchWaitSeconds", "connectReturnedBeforePublishWaitSeconds", "events"])
        XCTAssertEqual(initial["connectReturnedBeforePublishWaitSeconds"] as? Int, 0)
        XCTAssertEqual((initial["events"] as? [[String: Any]])?.count, 64)
        XCTAssertEqual(old.events.count, 64)
        let current = DictationRecoveryDiagnostic(configuration: configuration, outputURL: url)
        current.record(.preparationAccepted)
        let currentData = try Data(contentsOf: url)
        old.record(.readyPublished)
        XCTAssertEqual(try Data(contentsOf: url), currentData)
        let event = try XCTUnwrap(current.events.first)
        XCTAssertEqual(event.phase, .preparationAccepted)
        XCTAssertNil(event.snapshot)
        let encodedEvent = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(Set(encodedEvent.keys), ["phase", "time"])
    }

    func testPublishWaitPropagatesCancellationToTheExistingCleanupPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try XCTUnwrap(DictationRecoveryDiagnostic.Configuration(
            arguments: ["--speech-diagnostics", "--dictation-wait-before-publish"]))
        let diagnostic = DictationRecoveryDiagnostic(configuration: configuration,
            outputURL: directory.appendingPathComponent("diagnostic.json"))
        let task = Task { try await diagnostic.waitBeforePublish() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !diagnostic.waiting && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(diagnostic.accessibilityStatus, "phase=connect-returned-before-publish-wait-entered waiting=true")
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must reach the existing connection task's cleanup path.") }
        catch is CancellationError { }
        XCTAssertFalse(diagnostic.waiting)
        XCTAssertEqual(diagnostic.events.map(\.phase), [.publishWaitEntered, .publishWaitCancelled])
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("diagnostic.json"))) as? [String: Any])
        XCTAssertEqual(report["connectReturnedBeforePublishWaitSeconds"] as? Int, 30)
    }
}
#endif
