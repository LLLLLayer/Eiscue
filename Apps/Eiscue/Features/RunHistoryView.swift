import SwiftUI

struct RunHistoryView: View {
    @Environment(AppModel.self) private var model
    var conversationID: UUID? = nil

    private var records: [RunRecord] {
        var result = model.runs
        if let active = model.activeRun {
            result.removeAll { $0.id == active.id }
            result.append(active)
        }
        return result.filter { conversationID == nil || $0.conversationID == conversationID }
            .sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView("runs.empty", systemImage: "clock.arrow.circlepath",
                                       description: Text("runs.emptyDetail"))
            } else {
                List(records) { run in
                    NavigationLink {
                        RunDetailView(initialRecord: run)
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Label(run.state.title, systemImage: run.state.symbol)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(run.scope.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(run.startedAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.subheadline)
                            HStack {
                                Text(run.model).lineLimit(1)
                                Spacer()
                                Text("runs.eventCount \(run.events.count)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(EiscueStyle.background)
        .navigationTitle(conversationID == nil ? String(localized: "runs.title") : String(localized: "runs.conversationTitle"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    let initialRecord: RunRecord

    private var record: RunRecord {
        if let active = model.activeRun, active.id == initialRecord.id { return active }
        return model.runs.first { $0.id == initialRecord.id } ?? initialRecord
    }

    var body: some View {
        let timeline = record.timeline
        List {
            Section {
                Label(record.state.title, systemImage: record.state.symbol)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(record.state == .paused ? (record.pauseReason?.detail ?? record.state.explanation) : record.state.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LabeledContent("runs.scope", value: record.scope.title)
                LabeledContent("common.model", value: record.model)
                LabeledContent("runs.startTime") {
                    Text(record.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                if let end = record.endedAt {
                    LabeledContent("runs.endTime") {
                        Text(end, format: .dateTime.hour().minute().second())
                    }
                    LabeledContent("runs.duration", value: RunReport.duration(from: record.startedAt, to: end))
                }
                if let skill = record.skill {
                    LabeledContent("common.skill", value: skillName(skill))
                }
            }

            Section {
                if timeline.isEmpty {
                    Text("runs.noEvents").foregroundStyle(.secondary)
                } else {
                    ForEach(timeline) { item in
                        switch item {
                        case .activity(let activity):
                            NavigationLink {
                                RunToolDetailView(activityID: activity.id, initialRecord: record)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: activity.isRunning ? "circle.dotted.circle" : activity.isError ? "exclamationmark.circle" : "checkmark.circle")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(DeviceToolPresentation.activityTitle(for: activity)).font(.subheadline.weight(.medium))
                                        Text(activity.startedAt, format: .dateTime.hour().minute().second())
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 3)
                            }
                            .accessibilityIdentifier("runToolDetail_\(activity.id)")
                        case .event(let event):
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "circle.fill").font(.system(size: 5))
                                    .frame(width: 20, height: 20).foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(RunReport.eventTitle(event)).font(.subheadline.weight(.medium))
                                        Spacer()
                                        Text(event.date, format: .dateTime.hour().minute().second())
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Text(RunReport.eventSummary(event))
                                        .font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("runTimelineEvent_\(event.id)")
                        }
                    }
                }
            } header: {
                Text(String(localized: "runDetails.timeline", table: "RunDetails"))
                    .accessibilityIdentifier("runTimelineHeader")
            } footer: {
                Text("runs.logDetail")
            }

            Section {
                ShareLink(item: RunReport.text(record), subject: Text("runs.reportTitle")) {
                    Label("runs.shareReport", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("shareRunReportButton")
            }
        }
        .scrollContentBackground(.hidden)
        .background(EiscueStyle.background)
        .navigationTitle("runs.detailTitle")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func skillName(_ reference: String) -> String {
        let id = reference.components(separatedBy: "@").first ?? reference
        return model.skills.first { $0.id == id }?.name ?? String(localized: "common.recordedSkill")
    }
}

/// Reports deliberately format an allowlist of metadata, never raw errors,
/// prompts, tool arguments or credentials stored elsewhere in the application.
enum RunReport {
    static func eventTitle(_ event: RunLogEntry) -> String {
        switch event.kind {
        case "run.started": String(localized: "event.runStarted")
        case "tool.started": String(localized: "event.toolStarted")
        case "tool.finished": String(localized: "event.toolFinished")
        case "tool.failed": String(localized: "event.toolFailed")
        case "action.prepared": String(localized: "event.actionPrepared")
        case "action.dispatched": String(localized: "event.actionDispatched")
        case "action.acknowledged": String(localized: "event.actionAcknowledged")
        case "action.unknown": String(localized: "event.actionUnknown")
        case "observation.prepared": String(localized: "event.observationPrepared")
        case "observation.captured": String(localized: "event.observationCaptured")
        default: String(localized: "event.other")
        }
    }

    static func eventSummary(_ event: RunLogEntry) -> String {
        if event.kind == "run.started" { return String(localized: "event.startedSummary") }
        if event.kind == "observation.captured" {
            // Accept both the stable metadata format and records from earlier versions.
            let patterns = [
                #"^width=(\d{1,6});height=(\d{1,6});frame=([0-9a-fA-F-]{36})$"#,
                #"^(\d{1,6}) × (\d{1,6})，frame ([0-9a-fA-F-]{36})$"#
            ]
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern),
                      let match = expression.firstMatch(in: event.summary, range: NSRange(event.summary.startIndex..., in: event.summary)),
                      let widthRange = Range(match.range(at: 1), in: event.summary),
                      let heightRange = Range(match.range(at: 2), in: event.summary),
                      let frameRange = Range(match.range(at: 3), in: event.summary),
                      let width = Int(event.summary[widthRange]),
                      let height = Int(event.summary[heightRange]),
                      let frame = UUID(uuidString: String(event.summary[frameRange])) else { continue }
                return String(localized: "event.capturedMetadata \(width) \(height) \(frame.uuidString)")
            }
            return String(localized: "event.capturedSummary")
        }
        let name = event.summary.components(separatedBy: "：").first ?? ""
        guard let title = DeviceToolPresentation.title(for: name) else { return String(localized: "event.changedSummary") }
        switch event.kind {
        case "action.acknowledged": return String(localized: "event.acknowledgedSummary \(title)")
        case "action.unknown": return String(localized: "event.unknownSummary \(title)")
        default: return title
        }
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    static func text(_ run: RunRecord) -> String {
        var lines = [
            String(localized: "runs.reportTitle"),
            String(localized: "report.taskID \(run.id.uuidString)"),
            String(localized: "report.conversationID \(run.conversationID.uuidString)"),
            String(localized: "report.status \(run.state.title)"),
            String(localized: "report.scope \(run.scope.title)"),
            String(localized: "report.model \(run.model)"),
            String(localized: "report.started \(run.startedAt.ISO8601Format())")
        ]
        if let end = run.endedAt {
            lines.append(String(localized: "report.ended \(end.ISO8601Format())"))
            lines.append(String(localized: "report.duration \(duration(from: run.startedAt, to: end))"))
        }
        if run.state == .paused, let reason = run.pauseReason { lines.append(reason.detail) }
        lines += ["", String(localized: "runs.log")]
        lines += run.events.map { "\($0.date.ISO8601Format())  \(eventTitle($0)) · \(eventSummary($0))" }
        lines += ["", String(localized: "runs.reportPrivacy")]
        return lines.joined(separator: "\n")
    }
}

private extension RunState {
    var symbol: String {
        switch self {
        case .preparing: "hourglass"
        case .running: "circle.dotted.circle"
        case .completed: "checkmark.circle"
        case .paused: "pause.circle"
        case .interrupted: "pause.circle"
        case .failed: "exclamationmark.circle"
        }
    }
    var explanation: String {
        switch self {
        case .preparing: String(localized: "run.preparingDetail")
        case .running: String(localized: "run.runningDetail")
        case .completed: String(localized: "run.completedDetail")
        case .paused: String(localized: "run.pausedDetail")
        case .interrupted: String(localized: "run.interruptedDetail")
        case .failed: String(localized: "run.failedDetail")
        }
    }
}
