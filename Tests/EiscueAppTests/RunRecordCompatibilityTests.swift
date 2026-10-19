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
            XCTAssertNil(record.modelUsage)
            XCTAssertNil(record.modelUsageIsComplete)
        }
    }

    func testTokenTotalsKeepPartialAndMissingCountsDistinctFromZero() {
        let first = AgentModelUsage(id: UUID(), inputTokens: 31, outputTokens: 11, cacheReadTokens: 7, cacheWriteTokens: 0)
        let second = AgentModelUsage(id: UUID(), inputTokens: 19, outputTokens: 3)
        let input = RunTokenTotal([first, second], field: \.inputTokens)
        XCTAssertEqual(input.total, 50)
        XCTAssertEqual(input.reportedResponses, input.responseCount)
        let recovered = RunTokenTotal([first], field: \.inputTokens, isComplete: false)
        XCTAssertEqual(recovered.total, 31)
        XCTAssertNotEqual(recovered.displayValue, "31", "A recovered host journal can miss a durable response; never show its retained counts as complete.")
        let cache = RunTokenTotal([first, second], field: \.cacheReadTokens)
        XCTAssertEqual(cache.total, 7)
        XCTAssertEqual(cache.reportedResponses, 1)
        XCTAssertEqual(cache.responseCount, 2)
        XCTAssertNotEqual(cache.displayValue, "7", "Partial counts must not look like a complete task total.")
        XCTAssertEqual(RunTokenTotal([first], field: \.cacheWriteTokens).total, 0)
        XCTAssertNil(RunTokenTotal([second], field: \.cacheWriteTokens).total)
        XCTAssertNil(RunTokenTotal([], field: \.inputTokens).total)
        let large = AgentModelUsage(id: UUID(), inputTokens: Int.max)
        XCTAssertNil(RunTokenTotal([large, first], field: \.inputTokens).total, "Overflow must never become a plausible count.")
    }

    func testUsageResponseIdentityDeduplicatesWithoutMergingDifferentRounds() throws {
        var record = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(), scope: .chat,
                               model: "fixture", skill: nil, state: .completed, detail: "Done", events: [])
        let first = AgentModelUsage(id: UUID(), inputTokens: 31, outputTokens: 11)
        let second = AgentModelUsage(id: UUID(), inputTokens: 31, outputTokens: 11)
        record.recordModelUsage(first); record.recordModelUsage(first); record.recordModelUsage(second)
        record.modelUsageIsComplete = true
        XCTAssertEqual(record.modelUsage, [first, second])
        XCTAssertEqual(try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record)), record)
        XCTAssertNil(record.modelUsage?.first?.cacheReadTokens)
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
