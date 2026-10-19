import Foundation
import EiscueAgentKit

enum RunState: String, Codable, Sendable {
    case preparing, running, completed, paused, interrupted, failed, outcomeUnknown
    var title: String {
        switch self {
        case .preparing: String(localized: "run.preparing")
        case .running: String(localized: "run.running")
        case .completed: String(localized: "run.completed")
        case .paused: String(localized: "run.paused")
        case .interrupted: String(localized: "run.interrupted")
        case .failed: String(localized: "run.failed")
        case .outcomeUnknown: String(localized: "run.outcome_unknown", table: "Runtime")
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

struct RunRecord: Identifiable, Codable, Sendable, Equatable {
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
    var promptVersion: Int? = nil
    var stopCause: StopCause? = nil
    var cleanupFailure: String? = nil
    /// One immutable snapshot per runtime response; nil also supports old records.
    var modelUsage: [AgentModelUsage]? = nil
    /// Set only after the live response stream drains successfully. A crash
    /// can leave durable responses not yet journaled by the host.
    var modelUsageIsComplete: Bool? = nil

    mutating func recordModelUsage(_ usage: AgentModelUsage) {
        guard !(modelUsage ?? []).contains(where: { $0.id == usage.id }) else { return }
        if modelUsage == nil { modelUsage = [] }
        modelUsage?.append(usage)
    }

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

struct RunTokenTotal {
    let total: Int?
    let reportedResponses: Int
    let responseCount: Int
    let isComplete: Bool

    init(_ responses: [AgentModelUsage], field: KeyPath<AgentModelUsage, Int?>, isComplete: Bool = true) {
        self.isComplete = isComplete
        responseCount = responses.count
        let values = responses.compactMap { $0[keyPath: field] }.filter { $0 >= 0 }
        reportedResponses = values.count
        var sum = 0
        for value in values {
            let addition = sum.addingReportingOverflow(value)
            guard !addition.overflow else { total = nil; return }
            sum = addition.partialValue
        }
        total = values.isEmpty ? nil : sum
    }

    var displayValue: String {
        guard let total else { return String(localized: "runDetails.usage.unknown", table: "RunDetails") }
        if !isComplete || reportedResponses < responseCount {
            return String(localized: "runDetails.usage.partial \(total.formatted())", table: "RunDetails")
        }
        return total.formatted()
    }
}

struct RunLogEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let date: Date
    let kind: String
    let summary: String

    init(kind: String, summary: String) {
        id = UUID(); date = Date(); self.kind = kind; self.summary = summary
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

extension StopCause {
    var isOutcomeUnknown: Bool { if case .outcomeUnknown = self { true } else { false } }
}
extension RunRecord {
    var unknownActionTitle: String {
        guard case .outcomeUnknown(let name) = stopCause else { return "" }
        return DeviceToolPresentation.title(for: name) ?? String(localized: "run.unknown_action", table: "Runtime")
    }
}
