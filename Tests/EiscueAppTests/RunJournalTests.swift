import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

final class RunJournalTests: XCTestCase {
    func testNumberedUpdatesAppendOnlyNewEventsAndChangedActivities() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record()
        record.events = [RunLogEntry(kind: "first", summary: "original event")]
        record.activities = [ToolActivity(id: "read", name: "read_file", output: "unchanged payload")]
        let usage = AgentModelUsage(id: UUID(), inputTokens: 31, outputTokens: 11, cacheReadTokens: 7, cacheWriteTokens: 0)
        record.recordModelUsage(usage)
        try await fixture.journal.save(record)
        let first = try Data(contentsOf: fixture.entry(record.id, 1))
        record.events.append(RunLogEntry(kind: "second", summary: "new event"))
        try await fixture.journal.save(record)
        XCTAssertEqual(try Data(contentsOf: fixture.entry(record.id, 1)), first)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.entry(record.id, 2))) as? [String: Any])
        let delta = try XCTUnwrap(second["record"] as? [String: Any])
        XCTAssertEqual((delta["events"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue((delta["activities"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue((delta["modelUsage"] as? [[String: Any]])?.isEmpty == true, "Old usage snapshots are not rewritten in every event.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.summary(record.id).path))
        record.activities?[0].output = "finished payload"
        record.activities?[0].endedAt = Date()
        record.recordModelUsage(AgentModelUsage(id: UUID()))
        try await fixture.journal.save(record)
        let restored = try await RunJournal(directory: fixture.directory).load()
        XCTAssertEqual(restored.records, [record])
        XCTAssertTrue(restored.failures.isEmpty)
        XCTAssertEqual(restored.records.first?.modelUsage?.first, usage)
        XCTAssertEqual(restored.records.first?.modelUsage?.count, 2)
        XCTAssertNil(restored.records.first?.modelUsage?.last?.inputTokens)
    }

    func testSettledSummaryContainsLatestStateAndIdenticalRetryDoesNotAppend() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record()
        try await fixture.journal.save(record)
        record.events.append(RunLogEntry(kind: "run.finished", summary: "Done"))
        record.state = .completed; record.endedAt = Date()
        try await fixture.journal.save(record)
        let summary = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: fixture.summary(record.id)))
        XCTAssertEqual(summary, record)
        try await fixture.journal.save(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.entry(record.id, 3).path))
        let loadedRecords1 = try await RunJournal(directory: fixture.directory).load().records
        XCTAssertEqual(loadedRecords1, [record])
    }

    func testEmptyAndAbsentActivityCachesRoundTripWithoutChangingTheirMeaning() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record()
        try await fixture.journal.save(record)
        record.activities = []
        try await fixture.journal.save(record)
        let empty = try await RunJournal(directory: fixture.directory).load().records
        XCTAssertEqual(empty, [record])
        record.activities = nil
        try await fixture.journal.save(record)
        let absent = try await RunJournal(directory: fixture.directory).load().records
        XCTAssertEqual(absent, [record])
    }

    func testLegacyJSONLoadsAndItsExactBytesSurviveFirstJournalMutation() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record()
        record.events = [RunLogEntry(kind: "legacy", summary: "Saved before journals")]
        record.activities = [ToolActivity(id: "legacy-tool", name: "read_file", output: "retained")]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let original = try encoder.encode(record)
        try original.write(to: fixture.summary(record.id))
        let loadedRecords2 = try await fixture.journal.load().records
        XCTAssertEqual(loadedRecords2, [record])
        record.events.append(RunLogEntry(kind: "recovery", summary: "Interrupted"))
        record.state = .interrupted; record.endedAt = Date()
        try await fixture.journal.save(record)
        let backup = fixture.folder(record.id).appendingPathComponent("legacy.json")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let loadedRecords3 = try await RunJournal(directory: fixture.directory).load().records
        XCTAssertEqual(loadedRecords3, [record])
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testLegacyFixtureWithoutNewOptionalFieldsStillDecodes() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","conversationID":"00000000-0000-0000-0000-000000000002","requestID":"00000000-0000-0000-0000-000000000003","startedAt":100,"scope":"observe","model":"legacy-model","state":"completed","detail":"saved","events":[]}"#
        let record = try JSONDecoder().decode(RunRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.scope, .observe)
        XCTAssertNil(record.submission); XCTAssertNil(record.activities)
        XCTAssertNil(record.pauseReason); XCTAssertNil(record.promptVersion)
        XCTAssertNil(record.modelUsage)
    }

    func testSavingUnchangedLegacySummaryDoesNotReencodeItsOriginalBytes() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record(); record.state = .completed
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let original = try encoder.encode(record)
        try original.write(to: fixture.summary(record.id))
        try await fixture.journal.save(record)
        XCTAssertEqual(try Data(contentsOf: fixture.summary(record.id)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder(record.id).path))
    }

    func testMissingSequenceAndDamagedEntryStayIsolatedAndPreserved() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var damaged = fixture.record()
        let healthy = fixture.record()
        try await fixture.journal.save(damaged); try await fixture.journal.save(healthy)
        damaged.events.append(RunLogEntry(kind: "second", summary: "Keep"))
        try await fixture.journal.save(damaged)
        let original = try Data(contentsOf: fixture.entry(damaged.id, 2))
        try FileManager.default.removeItem(at: fixture.entry(damaged.id, 1))
        let journal = RunJournal(directory: fixture.directory)
        var loaded = try await journal.load()
        XCTAssertEqual(loaded.records, [healthy]); XCTAssertEqual(loaded.failures.count, 1)
        do { try await journal.save(damaged); XCTFail("A broken journal must not be overwritten.") } catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.entry(damaged.id, 2)), original)
        let partial = Data("{partial event".utf8)
        try partial.write(to: fixture.entry(damaged.id, 2))
        loaded = try await RunJournal(directory: fixture.directory).load()
        XCTAssertEqual(loaded.records, [healthy]); XCTAssertEqual(loaded.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.entry(damaged.id, 2)), partial)
    }

    func testDigestChainRejectsARewrittenEarlierEntry() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record()
        record.events = [RunLogEntry(kind: "first", summary: "original")]
        try await fixture.journal.save(record)
        record.events.append(RunLogEntry(kind: "second", summary: "second"))
        try await fixture.journal.save(record)
        let firstURL = fixture.entry(record.id, 1)
        let text = try String(contentsOf: firstURL, encoding: .utf8).replacingOccurrences(of: "original", with: "modified")
        let modified = Data(text.utf8); try modified.write(to: firstURL)
        let loaded = try await RunJournal(directory: fixture.directory).load()
        XCTAssertTrue(loaded.records.isEmpty); XCTAssertEqual(loaded.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: firstURL), modified)
    }

    func testRewritingCommittedEventHistoryIsRejectedBeforeWriting() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record()
        record.events = [RunLogEntry(kind: "first", summary: "Keep this event")]
        try await fixture.journal.save(record)
        let original = try Data(contentsOf: fixture.entry(record.id, 1))
        record.events = []
        do { try await fixture.journal.save(record); XCTFail("Committed history is append-only.") } catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.entry(record.id, 1)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.entry(record.id, 2).path))
    }

    func testLatestEntryChecksumDetectsValidJSONCorruptionWithoutASuccessor() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record()
        record.detail = "original detail"
        try await fixture.journal.save(record)
        let url = fixture.entry(record.id, 1)
        let corrupted = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "original detail", with: "altered detail")
        let bytes = Data(corrupted.utf8); try bytes.write(to: url)
        let loaded = try await RunJournal(directory: fixture.directory).load()
        XCTAssertTrue(loaded.records.isEmpty); XCTAssertEqual(loaded.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFailedSummaryWriteRetainsCommittedEventAndRetryDoesNotDuplicateIt() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var record = fixture.record()
        try await fixture.journal.save(record)
        try FileManager.default.createDirectory(at: fixture.summary(record.id), withIntermediateDirectories: true)
        record.state = .completed
        do { try await fixture.journal.save(record); XCTFail("Summary obstruction must propagate.") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.entry(record.id, 2).path))
        try FileManager.default.removeItem(at: fixture.summary(record.id))
        try await fixture.journal.save(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.entry(record.id, 3).path))
        let loadedRecords4 = try await RunJournal(directory: fixture.directory).load().records
        XCTAssertEqual(loadedRecords4, [record])
    }

    func testUncommittedStagingFilesAreIgnoredOnReopen() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let record = fixture.record()
        try await fixture.journal.save(record)
        let staging = fixture.folder(record.id).appendingPathComponent("interrupted.staging")
        let partial = Data("{unfinished append".utf8); try partial.write(to: staging)
        let loadedRecords5 = try await RunJournal(directory: fixture.directory).load().records
        XCTAssertEqual(loadedRecords5, [record])
        XCTAssertEqual(try Data(contentsOf: staging), partial)
    }

    func testDeletionUsesJournalOwnershipAndPreservesUnrelatedDamagedRun() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var removed = fixture.record(), kept = fixture.record()
        removed.state = .completed; kept.state = .completed
        try await fixture.journal.save(removed); try await fixture.journal.save(kept)
        let partial = Data("{damaged summary".utf8); try partial.write(to: fixture.summary(kept.id))
        let ids = try await fixture.journal.runIDsForDeletion(conversationID: removed.conversationID, knownRecords: [])
        XCTAssertEqual(ids, [removed.id])
        try await fixture.journal.delete(ids: ids)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder(removed.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.summary(removed.id).path))
        XCTAssertEqual(try Data(contentsOf: fixture.summary(kept.id)), partial)
        let unknown = fixture.directory.appendingPathComponent(UUID().uuidString + ".json")
        try partial.write(to: unknown)
        do {
            _ = try await fixture.journal.runIDsForDeletion(conversationID: kept.conversationID, knownRecords: [kept])
            XCTFail("Unknown ownership must stop cleanup.")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: unknown), partial)
    }

    func testCorruptedJournalOwnerCannotAuthorizeDeletionOfAnotherConversationsRun() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let record = fixture.record(), wrongOwner = UUID()
        try await fixture.journal.save(record)
        let first = fixture.entry(record.id, 1)
        let corrupted = try String(contentsOf: first, encoding: .utf8)
            .replacingOccurrences(of: record.conversationID.uuidString, with: wrongOwner.uuidString)
        let bytes = Data(corrupted.utf8); try bytes.write(to: first)
        do {
            _ = try await fixture.journal.runIDsForDeletion(conversationID: wrongOwner, knownRecords: [])
            XCTFail("Unverified ownership must stop cleanup preparation.")
        } catch { }
        let ids = try await fixture.journal.runIDsForDeletion(conversationID: wrongOwner, knownRecords: [record])
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(try Data(contentsOf: first), bytes)
    }

    private struct Fixture {
        let directory: URL
        let journal: RunJournal
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            journal = RunJournal(directory: directory)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func record() -> RunRecord {
            RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(), scope: .chat,
                      model: "fixture", skill: nil, state: .running, detail: "", events: [])
        }
        func summary(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
        func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".events") }
        func entry(_ id: UUID, _ sequence: Int) -> URL { folder(id).appendingPathComponent(String(format: "%020d.json", sequence)) }
    }
}
