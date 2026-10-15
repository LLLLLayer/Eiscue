import Foundation

enum RunState: String, Codable, Sendable {
    case preparing, running, completed, paused, interrupted, failed
    var title: String {
        switch self {
        case .preparing: String(localized: "run.preparing")
        case .running: String(localized: "run.running")
        case .completed: String(localized: "run.completed")
        case .paused: String(localized: "run.paused")
        case .interrupted: String(localized: "run.interrupted")
        case .failed: String(localized: "run.failed")
        }
    }
}

enum RunPauseReason: String, Codable, Sendable {
    case toolLimit, noProgress, verification, connection

    var detail: String {
        switch self {
        case .toolLimit: String(localized: "run.paused.toolLimit", table: "Runtime")
        case .noProgress: String(localized: "run.paused.noProgress", table: "Runtime")
        case .verification: String(localized: "run.paused.verification", table: "Runtime")
        case .connection: String(localized: "run.paused.connection", table: "Runtime")
        }
    }
}

enum RunSubmission: String, Codable, Sendable { case pending, accepted, abandoned }

struct RunRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let conversationID: UUID
    let requestID: UUID
    let startedAt: Date
    let scope: TaskScope
    let model: String
    let skill: String?
    var state: RunState
    var endedAt: Date?
    var detail: String
    var events: [RunLogEntry]
    var submission: RunSubmission? = nil
    var activities: [ToolActivity]? = nil
    var pauseReason: RunPauseReason? = nil

    mutating func interruptOpenActivities(at date: Date = Date()) {
        guard var activities else { return }
        for index in activities.indices where activities[index].isRunning {
            activities[index].endedAt = date
            activities[index].isError = true
            activities[index].output = String(localized: "activity.interrupted", table: "Activities")
        }
        self.activities = activities
    }
}

struct RunLogEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let kind: String
    let summary: String

    init(kind: String, summary: String) {
        id = UUID(); date = Date(); self.kind = kind; self.summary = summary
    }
}

/// A per-run file makes the send boundary durable without rewriting all chat history.
actor RunJournal {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func save(_ record: RunRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        let url = directory.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var protectedURL = url; try protectedURL.setResourceValues(values)
    }

    /// An unreadable record is reported and left on disk; it never hides the
    /// readable history or the interrupted state of other conversations.
    func load() throws -> (records: [RunRecord], failures: [String]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var records: [RunRecord] = [], failures: [String] = []
        for url in urls where url.pathExtension == "json" {
            do { records.append(try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: url))) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (records.sorted { $0.startedAt > $1.startedAt }, failures)
    }

    func delete(_ records: [RunRecord]) throws {
        try delete(ids: Set(records.map(\.id)))
    }

    func runIDsForDeletion(conversationID: UUID, knownRecords: [RunRecord]) throws -> Set<UUID> {
        var ids = Set(knownRecords.filter { $0.conversationID == conversationID }.map(\.id))
        guard FileManager.default.fileExists(atPath: directory.path) else { return ids }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in urls where url.pathExtension == "json" {
            let identity: RecordIdentity
            do {
                identity = try JSONDecoder().decode(RecordIdentity.self, from: Data(contentsOf: url))
            } catch {
                // A damaged payload can still be removed when this session
                // already knows its owner. Unknown ownership must stop cleanup.
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let known = knownRecords.first(where: { $0.id == id }) else { throw error }
                if known.conversationID == conversationID { ids.insert(id) }
                continue
            }
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == identity.id else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if identity.conversationID == conversationID { ids.insert(identity.id) }
            else { ids.remove(identity.id) }
        }
        return ids
    }

    func delete(ids: Set<UUID>) throws {
        for id in ids {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")) }
            catch CocoaError.fileNoSuchFile { continue }
        }
    }

    private struct RecordIdentity: Decodable {
        let id: UUID
        let conversationID: UUID
    }
}

/// A single chronology retains every diagnostic event and the drill-down entry
/// for each operation; identical timestamps keep their original order.
enum RunTimelineItem: Identifiable {
    case activity(ToolActivity)
    case event(RunLogEntry)
    var id: String {
        switch self { case .activity(let value): "activity:\(value.id)"; case .event(let value): "event:\(value.id)" }
    }
    var date: Date {
        switch self { case .activity(let value): value.startedAt; case .event(let value): value.date }
    }
}

extension RunRecord {
    var timeline: [RunTimelineItem] {
        let items = events.map(RunTimelineItem.event) + (activities ?? []).map(RunTimelineItem.activity)
        return items.enumerated().sorted {
            $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date
        }.map(\.element)
    }
}
