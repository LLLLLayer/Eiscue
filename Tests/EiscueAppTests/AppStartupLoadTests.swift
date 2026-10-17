import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor final class AppStartupLoadTests: XCTestCase {
    func testDamagedRunRecordKeepsReadableHistoryAndInterruptedState() async throws {
        let fixture = try LoadFixture()
        defer { fixture.cleanUp() }
        let conversation = Conversation(title: "Kept", messages: [AgentMessage(role: .user, text: "Hello")])
        try await JSONConversationRepository(fileURL: fixture.directory.appendingPathComponent("conversations.json")).save(conversation)
        let journal = RunJournal(directory: fixture.directory.appendingPathComponent("Runs", isDirectory: true))
        let unfinished = RunRecord(id: UUID(), conversationID: conversation.id, requestID: UUID(), startedAt: Date(), scope: .chat,
                                   model: "fixture", skill: nil, state: .running, detail: "", events: [])
        try await journal.save(unfinished)
        try Data("{damaged".utf8).write(to: fixture.directory.appendingPathComponent("Runs/\(UUID().uuidString).json"))

        let model = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences)
        await model.load()

        XCTAssertEqual(model.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(model.runs.map(\.id), [unfinished.id])
        XCTAssertEqual(model.runs.first?.state, .interrupted, "A run left running is recovered as interrupted.")
        XCTAssertTrue(model.interruptedConversationIDs.contains(conversation.id))
        XCTAssertFalse(model.skills.isEmpty, "Skills still load after a run record fails.")
        XCTAssertNotNil(model.errorMessage, "The damaged record is reported instead of silently ignored.")
        XCTAssertFalse(model.isLoading)
    }

    func testDamagedConversationFileStillLoadsRunsAndSkills() async throws {
        let fixture = try LoadFixture()
        defer { fixture.cleanUp() }
        let file = fixture.directory.appendingPathComponent("conversations.json")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let original = Data("not a conversation store".utf8)
        try original.write(to: file)
        let journal = RunJournal(directory: fixture.directory.appendingPathComponent("Runs", isDirectory: true))
        let finished = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(), scope: .chat,
                                 model: "fixture", skill: nil, state: .completed, detail: "", events: [])
        try await journal.save(finished)

        let model = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences)
        await model.load()

        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertEqual(model.runs.map(\.id), [finished.id])
        XCTAssertFalse(model.skills.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), original, "Loading never replaces a damaged store.")
    }

    func testDamagedConversationRecordReportsFailureWhileHealthyHistoryLoads() async throws {
        let fixture = try LoadFixture()
        defer { fixture.cleanUp() }
        let file = fixture.directory.appendingPathComponent("conversations.json")
        let repository = JSONConversationRepository(fileURL: file)
        let healthy = Conversation(title: "Readable", messages: [.init(role: .user, text: "Keep my history")])
        let damaged = Conversation(title: "Damaged")
        try await repository.save(healthy); try await repository.save(damaged)
        let record = file.appendingPathExtension("store").appendingPathComponent(damaged.id.uuidString.lowercased() + ".json")
        let original = Data("{partial conversation".utf8)
        try original.write(to: record)

        let model = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences)
        await model.load()

        XCTAssertEqual(model.conversations, [healthy])
        XCTAssertNotNil(model.errorMessage, "Corrupt IDs must be reported instead of silently shortening the list.")
        XCTAssertFalse(model.skills.isEmpty)
        XCTAssertEqual(try Data(contentsOf: record), original)
        XCTAssertFalse(model.isLoading)
    }
}

@MainActor private struct LoadFixture {
    let suite = "AppStartupLoadTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let preferences: UserDefaults

    init() throws { preferences = try XCTUnwrap(UserDefaults(suiteName: suite)) }

    func cleanUp() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
