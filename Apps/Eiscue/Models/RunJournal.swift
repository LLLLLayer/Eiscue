import CryptoKit
import Foundation

/// One instance per directory serializes append-only, numbered updates. Final
/// summaries are replaceable projections; legacy JSON is retained byte for byte.
actor RunJournal {
    let directory: URL
    private var cached: [UUID: JournalState] = [:]
    init(directory: URL) { self.directory = directory }

    func save(_ record: RunRecord) throws {
        let previous = try cached[record.id] ?? readState(record.id)
        if let previous {
            guard Self.sameIdentity(previous.record, record),
                  record.events.starts(with: previous.record.events),
                  (record.modelUsage ?? []).starts(with: previous.record.modelUsage ?? []),
                  (record.activities ?? []).map(\.id).starts(with: (previous.record.activities ?? []).map(\.id)) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        guard Set(record.events.map(\.id)).count == record.events.count,
              Set((record.modelUsage ?? []).map(\.id)).count == (record.modelUsage ?? []).count,
              Set((record.activities ?? []).map(\.id)).count == (record.activities ?? []).count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if previous?.record == record {
            if (previous?.sequence ?? 0) > 0, Self.isSettled(record) { try writeSummary(record) }
            return
        }
        let folder = journalURL(record.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The first mutation of a legacy record keeps its exact original bytes.
        if previous?.sequence == 0 {
            let original = try Data(contentsOf: recordURL(record.id))
            let backup = folder.appendingPathComponent("legacy.json")
            if FileManager.default.fileExists(atPath: backup.path) {
                guard try Data(contentsOf: backup) == original else { throw CocoaError(.fileWriteFileExists) }
            } else { try write(original, to: backup) }
        }
        var delta = record
        let priorJournalRecord = (previous?.sequence ?? 0) > 0 ? previous?.record : nil
        delta.events = Array(record.events.dropFirst(priorJournalRecord?.events.count ?? 0))
        delta.modelUsage = record.modelUsage.map { Array($0.dropFirst(priorJournalRecord?.modelUsage?.count ?? 0)) }
        let previousActivities = Dictionary(uniqueKeysWithValues: (priorJournalRecord?.activities ?? []).map { ($0.id, $0) })
        delta.activities = record.activities.map { $0.filter { previousActivities[$0.id] != $0 } }
        let entry = try Entry(sequence: (previous?.sequence ?? 0) + 1, previousDigest: previous?.digest, record: delta)
        let data = try JSONEncoder().encode(entry)
        let destination = eventURL(record.id, sequence: entry.sequence)
        // A staged sibling is never considered an event. Rename commits one
        // complete entry and refuses to replace a sequence already on disk.
        let staged = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("staging")
        defer { try? FileManager.default.removeItem(at: staged) }
        try write(data, to: staged)
        try FileManager.default.moveItem(at: staged, to: destination)
        cached[record.id] = JournalState(record: record, sequence: entry.sequence, digest: Self.digest(data))
        if Self.isSettled(record) { try writeSummary(record) }
    }

    /// A damaged run is preserved and reported without hiding other history.
    func load() throws -> (records: [RunRecord], failures: [String]) {
        let ids = try storedIDs()
        cached.removeAll()
        var records: [RunRecord] = [], failures: [String] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                if let state = try readState(id) { records.append(state.record); cached[id] = state }
            } catch { failures.append("\(id.uuidString): \(error.localizedDescription)") }
        }
        // Preserve reporting for damaged legacy files whose filename isn't an ID.
        for url in try contents() where url.pathExtension == "json" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) == nil {
            failures.append("\(url.lastPathComponent): \(CocoaError(.fileReadCorruptFile).localizedDescription)")
        }
        return (records.sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt }, failures)
    }

    func delete(_ records: [RunRecord]) throws { try delete(ids: Set(records.map(\.id))) }

    func runIDsForDeletion(conversationID: UUID, knownRecords: [RunRecord]) throws -> Set<UUID> {
        var ids = Set(knownRecords.filter { $0.conversationID == conversationID }.map(\.id))
        for id in try storedIDs() {
            let identity: RecordIdentity
            do { identity = try readIdentity(id) }
            catch {
                // Known ownership authorizes removal of an unreadable run;
                // unknown ownership must stop the entire cleanup preparation.
                guard let known = knownRecords.first(where: { $0.id == id }) else { throw error }
                if known.conversationID == conversationID { ids.insert(id) }
                continue
            }
            guard identity.id == id else { throw CocoaError(.fileReadCorruptFile) }
            if identity.conversationID == conversationID { ids.insert(id) } else { ids.remove(id) }
        }
        for url in try contents() where url.pathExtension == "json" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) == nil {
            throw CocoaError(.fileReadCorruptFile)
        }
        return ids
    }

    func delete(ids: Set<UUID>) throws {
        for id in ids {
            try removeIfPresent(recordURL(id))
            try removeIfPresent(journalURL(id))
            cached.removeValue(forKey: id)
        }
    }

    private func readState(_ id: UUID) throws -> JournalState? {
        let folder = journalURL(id)
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { files = [] }
        let events = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "legacy.json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if events.isEmpty {
            // A crash before the first rename leaves no committed events.
            do {
                let record = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: recordURL(id)))
                guard record.id == id else { throw CocoaError(.fileReadCorruptFile) }
                return .init(record: record, sequence: 0, digest: nil)
            } catch CocoaError.fileReadNoSuchFile { return nil }
        }
        var state: JournalState?
        for (offset, url) in events.enumerated() {
            let data = try Data(contentsOf: url)
            let entry = try JSONDecoder().decode(Entry.self, from: data)
            guard entry.version == 1, entry.sequence == offset + 1,
                  url.lastPathComponent == eventURL(id, sequence: entry.sequence).lastPathComponent,
                  entry.previousDigest == state?.digest, entry.record.id == id,
                  try entry.hasValidChecksum() else { throw CocoaError(.fileReadCorruptFile) }
            if let state { guard Self.sameIdentity(state.record, entry.record) else { throw CocoaError(.fileReadCorruptFile) } }
            var record = entry.record
            record.events = (state?.record.events ?? []) + entry.record.events
            guard Set(record.events.map(\.id)).count == record.events.count else { throw CocoaError(.fileReadCorruptFile) }
            if let updates = entry.record.modelUsage {
                record.modelUsage = (state?.record.modelUsage ?? []) + updates
                guard Set(record.modelUsage!.map(\.id)).count == record.modelUsage!.count else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                guard state?.record.modelUsage?.isEmpty != false else { throw CocoaError(.fileReadCorruptFile) }
            }
            if let updates = entry.record.activities {
                guard Set(updates.map(\.id)).count == updates.count else { throw CocoaError(.fileReadCorruptFile) }
                var activities = state?.record.activities ?? []
                for activity in updates {
                    if let index = activities.firstIndex(where: { $0.id == activity.id }) { activities[index] = activity }
                    else { activities.append(activity) }
                }
                record.activities = activities
            } else {
                guard state?.record.activities?.isEmpty != false else { throw CocoaError(.fileReadCorruptFile) }
                record.activities = nil
            }
            state = .init(record: record, sequence: entry.sequence, digest: Self.digest(data))
        }
        // The summary is a derived cache. A failed summary write can leave an
        // older valid summary; numbered entries always determine current state.
        if FileManager.default.fileExists(atPath: recordURL(id).path) {
            let summary = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: recordURL(id)))
            guard let state, Self.sameIdentity(summary, state.record) else { throw CocoaError(.fileReadCorruptFile) }
        }
        return state
    }

    private func readIdentity(_ id: UUID) throws -> RecordIdentity {
        let first = eventURL(id, sequence: 1)
        if FileManager.default.fileExists(atPath: first.path) {
            let value = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: first))
            guard value.version == 1, value.sequence == 1, value.previousDigest == nil,
                  value.record.id == id, try value.hasValidChecksum() else { throw CocoaError(.fileReadCorruptFile) }
            return RecordIdentity(id: value.record.id, conversationID: value.record.conversationID)
        }
        return try JSONDecoder().decode(RecordIdentity.self, from: Data(contentsOf: recordURL(id)))
    }

    private func storedIDs() throws -> Set<UUID> {
        Set(try contents().filter { $0.pathExtension == "json" || $0.pathExtension == "events" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
    }

    private func contents() throws -> [URL] {
        do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { return [] }
    }

    private func writeSummary(_ record: RunRecord) throws { try write(try JSONEncoder().encode(record), to: recordURL(record.id)) }
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var protectedURL = url; try protectedURL.setResourceValues(values)
    }
    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile { return }
    }
    private func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    private func journalURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("events") }
    private func eventURL(_ id: UUID, sequence: Int) -> URL {
        journalURL(id).appendingPathComponent(String(format: "%020d.json", sequence))
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isSettled(_ record: RunRecord) -> Bool { record.state != .preparing && record.state != .running }
    private static func sameIdentity(_ lhs: RunRecord, _ rhs: RunRecord) -> Bool {
        lhs.id == rhs.id && lhs.conversationID == rhs.conversationID && lhs.requestID == rhs.requestID && lhs.startedAt == rhs.startedAt &&
            lhs.scope == rhs.scope && lhs.model == rhs.model && lhs.skill == rhs.skill
    }
    private struct JournalState { let record: RunRecord; let sequence: Int; let digest: String? }
    private struct Entry: Codable {
        let version: Int
        let sequence: Int
        let previousDigest: String?
        let record: RunRecord
        let checksum: String

        init(sequence: Int, previousDigest: String?, record: RunRecord) throws {
            version = 1; self.sequence = sequence; self.previousDigest = previousDigest; self.record = record
            checksum = try Self.checksum(version: version, sequence: sequence, previousDigest: previousDigest, record: record)
        }
        func hasValidChecksum() throws -> Bool {
            try checksum == Self.checksum(version: version, sequence: sequence, previousDigest: previousDigest, record: record)
        }
        private static func checksum(version: Int, sequence: Int, previousDigest: String?, record: RunRecord) throws -> String {
            struct Payload: Encodable { let version: Int; let sequence: Int; let previousDigest: String?; let record: RunRecord }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return RunJournal.digest(try encoder.encode(Payload(version: version, sequence: sequence, previousDigest: previousDigest, record: record)))
        }
    }
    private struct RecordIdentity: Decodable { let id: UUID; let conversationID: UUID }
}
