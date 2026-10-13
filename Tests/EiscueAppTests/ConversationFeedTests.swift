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
        XCTAssertEqual(loaded.records.first?.activities, record.activities)
        XCTAssertTrue(loaded.failures.isEmpty)
    }

    func testUnreadableRunRecordDoesNotHideReadableHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RunJournal(directory: directory)
        let readable = record()
        try await journal.save(readable)
        let damaged = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{not json".utf8).write(to: damaged)

        let loaded = try await journal.load()
        XCTAssertEqual(loaded.records.map(\.id), [readable.id])
        XCTAssertEqual(loaded.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path), "A damaged record is preserved for inspection.")
        try await journal.delete([readable, readable])
        let remaining = try await journal.load().records
        XCTAssertTrue(remaining.isEmpty, "Deleting an already removed record is not an error.")
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

    @MainActor func testControlProgressPublishesAtStepBoundariesAndHoldsOnlyObservedInterval() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let user = AgentMessage(role: .user, text: "Switch to dark mode")
        let conversation = Conversation(title: "Device task", messages: [user])
        model.conversations = [conversation]; model.selectedConversationID = conversation.id
        let run = fixture.run(conversation: conversation, requestID: user.id)
        model.activeRun = run
        XCTAssertFalse(model.isHoldingDeviceTranscript, "Starting a run must not hide all its progress.")
        model.streamingText = "Checking the screen"
        model.holdDeviceTranscript(for: run.id)
        let tool = ToolActivity(id: "run:call", name: "device_screenshot", precedingMessageID: user.id)
        model.activeRun?.activities = [tool]
        model.streamingText = "Choosing a visible control"
        let reply = AgentMessage(role: .assistant, text: "Next I will open Settings")
        model.conversations[0].messages.append(reply)
        XCTAssertEqual(model.displayedConversationFeed, [.message(user)])
        XCTAssertEqual(model.displayedStreamingText, "Checking the screen", "Keep the exact visible text, without removing it on capture.")

        model.releaseDeviceTranscript(for: run.id)
        XCTAssertFalse(model.isHoldingDeviceTranscript)
        XCTAssertEqual(model.displayedConversationFeed, model.conversationFeed)
        XCTAssertEqual(model.displayedStreamingText, "Choosing a visible control")
        XCTAssertNotNil(model.activeRun, "Progress becomes visible before the entire task finishes.")
        model.activeRun?.activities?[0].endedAt = Date()
        model.activeRun?.activities?[0].output = "Observed"
        model.holdDeviceTranscript(for: run.id)
        let secondStep = model.displayedConversationFeed
        model.conversations[0].messages.append(AgentMessage(role: .assistant, text: "Another step"))
        XCTAssertEqual(model.displayedConversationFeed, secondStep)
        model.activeRun?.state = .completed
        model.runs = [try XCTUnwrap(model.activeRun)]
        model.activeRun = nil
        XCTAssertFalse(model.isHoldingDeviceTranscript)
        XCTAssertEqual(model.displayedConversationFeed.count, 4)
    }

    @MainActor func testOldStepCallbacksCannotFreezeOrReleaseAnotherRun() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let user = AgentMessage(role: .user, text: "Change appearance")
        let conversation = Conversation(title: "Continue", messages: [user])
        model.conversations = [conversation]; model.selectedConversationID = conversation.id
        let first = fixture.run(conversation: conversation, requestID: user.id)
        model.activeRun = first; model.holdDeviceTranscript(for: first.id)
        let next = fixture.run(conversation: conversation, requestID: user.id)
        model.activeRun = next
        XCTAssertFalse(model.isHoldingDeviceTranscript)
        model.holdDeviceTranscript(for: first.id)
        XCTAssertFalse(model.isHoldingDeviceTranscript)
        model.holdDeviceTranscript(for: next.id)
        model.releaseDeviceTranscript(for: first.id)
        XCTAssertTrue(model.isHoldingDeviceTranscript)
        model.activeRun = nil
        XCTAssertFalse(model.isHoldingDeviceTranscript)
    }

    @MainActor func testChatAndObserveStayLiveAndPresentationUsesCapturedRunScope() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        for scope in [TaskScope.chat, .observe] {
            let user = AgentMessage(role: .user, text: "Hello")
            let conversation = Conversation(title: "Live", messages: [user])
            model.conversations = [conversation]; model.selectedConversationID = conversation.id
            let run = fixture.run(conversation: conversation, requestID: user.id, scope: scope)
            model.activeRun = run; model.scope = .control
            model.holdDeviceTranscript(for: run.id)
            model.streamingText = "Live response"
            model.conversations[0].messages.append(AgentMessage(role: .assistant, text: "Finished"))
            XCTAssertFalse(model.isHoldingDeviceTranscript)
            XCTAssertEqual(model.displayedStreamingText, "Live response")
            XCTAssertEqual(model.displayedConversationFeed, model.conversationFeed)
            model.activeRun = nil
        }
        let conversation = try XCTUnwrap(model.selectedConversation)
        let run = fixture.run(conversation: conversation, requestID: UUID())
        model.activeRun = run; model.scope = .chat
        model.holdDeviceTranscript(for: run.id)
        XCTAssertTrue(model.isHoldingDeviceTranscript, "Composer scope must not change an active run's presentation.")
        let other = Conversation(title: "Other", messages: [AgentMessage(role: .user, text: "History")])
        model.conversations.append(other); model.selectedConversationID = other.id
        XCTAssertFalse(model.isHoldingDeviceTranscript)
        XCTAssertEqual(model.displayedConversationFeed, [.message(other.messages[0])])
    }

    private func record() -> RunRecord {
        RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(), scope: .chat,
                  model: "fixture", skill: nil, state: .running, detail: "", events: [])
    }
}

@MainActor private struct TranscriptFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "eiscue.transcript-tests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let model: AppModel

    init() throws {
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        model = AppModel(storageDirectory: directory, preferences: preferences)
    }
    func run(conversation: Conversation, requestID: UUID, scope: TaskScope = .control) -> RunRecord {
        RunRecord(id: UUID(), conversationID: conversation.id, requestID: requestID, startedAt: Date(), scope: scope,
                  model: "fixture", skill: nil, state: .preparing, detail: "", events: [])
    }
    func cleanUp() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
