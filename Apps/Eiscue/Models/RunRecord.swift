import Foundation

enum RunState: String, Codable, Sendable {
    case preparing, running, completed, interrupted, failed
    var title: String {
        switch self {
        case .preparing: String(localized: "run.preparing")
        case .running: String(localized: "run.running")
        case .completed: String(localized: "run.completed")
        case .interrupted: String(localized: "run.interrupted")
        case .failed: String(localized: "run.failed")
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
        for record in records {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")) }
            catch CocoaError.fileNoSuchFile { continue }
        }
    }
}
