import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

final class ConversationFeedTests: XCTestCase {
    func testChronologicalMessagesAndRealToolsRemainSeparateAndDeduplicated() {
        let time = Date(timeIntervalSince1970: 1_000)
        let user = AgentMessage(role: .user, text: "Inspect", createdAt: time)
        let first = AgentMessage(role: .assistant, text: "First reply", createdAt: time.addingTimeInterval(1))
        let tool = ToolActivity(id: "run-1:call-1", name: "read_file", startedAt: time.addingTimeInterval(2))
        let last = AgentMessage(role: .assistant, text: "Result", createdAt: time.addingTimeInterval(3))
        XCTAssertEqual(ConversationFeedItem.merge(messages: [user, first, first, last], activities: [tool, tool]),
                       [.message(user), .message(first), .activity(tool), .message(last)])
    }

    func testSameProviderCallIDInDifferentRunsDoesNotLoseAnActivity() {
        let time = Date()
        let first = ToolActivity(id: "run-1:call-1", name: "read_file", startedAt: time)
        let second = ToolActivity(id: "run-2:call-1", name: "read_file", startedAt: time)
        XCTAssertEqual(ConversationFeedItem.merge(messages: [], activities: [first, second]), [.activity(first), .activity(second)])
    }

    func testProviderRoundedTimestampCannotMoveReplyBeforeItsTool() {
        let time = Date(timeIntervalSince1970: 1_000)
        let first = AgentMessage(role: .assistant, text: "Inspecting", createdAt: time)
        let tool = ToolActivity(id: "run:call", name: "read_file", startedAt: time.addingTimeInterval(0.8), precedingMessageID: first.id)
        let final = AgentMessage(role: .assistant, text: "Done", createdAt: time)
        XCTAssertEqual(ConversationFeedItem.merge(messages: [first, final], activities: [tool]),
                       [.message(first), .activity(tool), .message(final)])
    }

    func testDelayedHostToolEventCannotReorderRuntimeMessages() {
        let time = Date(timeIntervalSince1970: 1_000)
        let user = AgentMessage(role: .user, text: "Question", createdAt: time.addingTimeInterval(0.9))
        let first = AgentMessage(role: .assistant, text: "Inspecting", createdAt: time)
        let final = AgentMessage(role: .assistant, text: "Done", createdAt: time.addingTimeInterval(1))
        let tool = ToolActivity(id: "run:call", name: "read_file", startedAt: time.addingTimeInterval(3), precedingMessageID: first.id)
        XCTAssertEqual(ConversationFeedItem.merge(messages: [user, first, final], activities: [tool]),
                       [.message(user), .message(first), .activity(tool), .message(final)])
    }

    func testResumedRunActivitiesWithSameMessageAnchorKeepOldRunFirst() {
        let time = Date(timeIntervalSince1970: 1_000)
        let message = AgentMessage(role: .user, text: "Continue", createdAt: time)
        let older = ToolActivity(id: "older:call", name: "inspect", startedAt: time.addingTimeInterval(1), precedingMessageID: message.id)
        let resumed = ToolActivity(id: "resumed:call", name: "inspect", startedAt: time.addingTimeInterval(2), precedingMessageID: message.id)
        XCTAssertEqual(ConversationFeedItem.merge(messages: [message], activities: [resumed, older]),
                       [.message(message), .activity(older), .activity(resumed)])
    }

    func testArgumentsKeepUsefulParametersAndRedactNestedCredentialFields() throws {
        let value: AgentJSONValue = ["path": "document.txt", "command": "cat document.txt",
                                    "nested": ["api_key": "secret-one", "Authorization": "secret-two"],
                                    "array": .array([["refresh-token": "secret-three"]])]
        let formatted = ToolActivityFormatting.arguments(value)
        XCTAssertTrue(formatted.contains("document.txt"))
        XCTAssertTrue(formatted.contains("cat document.txt"))
        XCTAssertFalse(formatted.contains("secret-one"))
        XCTAssertFalse(formatted.contains("secret-two"))
        XCTAssertFalse(formatted.contains("secret-three"))
        XCTAssertEqual(formatted.components(separatedBy: "[redacted]").count - 1, 3)
    }

    func testOldJournalsDecodeAndNewActivitiesSurvivePersistence() async throws {
        var record = record()
        record.activities = [ToolActivity(id: "run:call", name: "read_file", endedAt: Date(), arguments: "document.txt", output: "Found", isError: false)]
        let data = try JSONEncoder().encode(record)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "activities")
        let oldRecord = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(oldRecord.activities)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RunJournal(directory: directory)
        try await journal.save(record)
        let loaded = try await journal.load()
        XCTAssertEqual(loaded.first?.activities, record.activities)
    }

    func testInterruptedRunClosesOnlyUnfinishedTools() {
        var record = record()
        let finished = ToolActivity(id: "finished", name: "read_file", endedAt: Date(), output: "Real result")
        record.activities = [finished, ToolActivity(id: "unfinished", name: "write_file")]
        let stoppedAt = Date(timeIntervalSince1970: 2_000)
        record.interruptOpenActivities(at: stoppedAt)
        XCTAssertEqual(record.activities?.first, finished)
        XCTAssertEqual(record.activities?.last?.endedAt, stoppedAt)
        XCTAssertEqual(record.activities?.last?.isError, true)
        XCTAssertFalse(record.activities?.last?.isRunning ?? true)
        XCTAssertFalse(record.activities?.last?.output.isEmpty ?? true)
    }

    private func record() -> RunRecord {
        RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(), scope: .chat,
                  model: "fixture", skill: nil, state: .running, detail: "", events: [])
    }
}
