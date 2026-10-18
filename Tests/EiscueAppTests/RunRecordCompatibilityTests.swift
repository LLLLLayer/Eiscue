import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

final class RunRecordCompatibilityTests: XCTestCase {
    func testPreIterationRecordsKeepAllHistoricalScopesWithoutNewOptionalFields() throws {
        for scope in ["chat", "observe", "control"] {
            let json = """
            {"id":"00000000-0000-0000-0000-000000000001","conversationID":"00000000-0000-0000-0000-000000000002",
             "requestID":"00000000-0000-0000-0000-000000000003","startedAt":100,"scope":"\(scope)","model":"legacy-model",
             "state":"interrupted","detail":"Saved before typed outcomes","events":[]}
            """
            let record = try JSONDecoder().decode(RunRecord.self, from: Data(json.utf8))
            XCTAssertEqual(record.scope.rawValue, scope)
            XCTAssertEqual(record.state, .interrupted)
            XCTAssertNil(record.submission); XCTAssertNil(record.activities); XCTAssertNil(record.pauseReason)
            XCTAssertNil(record.promptVersion); XCTAssertNil(record.stopCause); XCTAssertNil(record.cleanupFailure)
        }
    }

    func testNewUnknownOutcomeAndCleanupFailureRoundTripIndependently() throws {
        var record = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(), scope: .control,
                               model: "fixture", skill: nil, state: .outcomeUnknown, detail: "Review visible result", events: [])
        record.stopCause = .outcomeUnknown(toolName: DeviceToolSpec.tap.rawValue)
        record.cleanupFailure = "Disconnect could not be confirmed"
        let restored = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(restored.state, .outcomeUnknown)
        XCTAssertTrue(restored.stopCause?.isOutcomeUnknown == true)
        XCTAssertNotNil(restored.cleanupFailure)
    }

    func testBackgroundExpirationRoundTripsAsDistinctFromAUserStop() throws {
        var record = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(), scope: .control,
                               model: "fixture", skill: nil, state: .interrupted, detail: "Background execution ended", events: [])
        record.stopCause = .backgroundExpired
        let restored = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(restored.stopCause, .backgroundExpired)
        XCTAssertNotEqual(restored.stopCause, .userRequested)
        XCTAssertFalse(restored.stopCause?.isOutcomeUnknown == true)
        let historical = try JSONDecoder().decode(StopCause.self, from: Data(#"{"userRequested":{}}"#.utf8))
        XCTAssertEqual(historical, .userRequested)
    }
}
