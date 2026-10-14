import EiscueAgentKit
import Foundation

/// Presentation of a real tool call, separate from the assistant's prose.
/// Screen image bytes stay out of the run journal.
struct ToolActivity: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let startedAt: Date
    var endedAt: Date?
    let arguments: String
    var output: String
    var isError: Bool
    /// Event order cannot be inferred from provider timestamps, which may be
    /// rounded to a second. Anchor the activity to the preceding stored message.
    var precedingMessageID: UUID?

    var isRunning: Bool { endedAt == nil }

    init(id: String, name: String, startedAt: Date = Date(), endedAt: Date? = nil,
         arguments: String = "", output: String = "", isError: Bool = false, precedingMessageID: UUID? = nil) {
        self.id = id; self.name = name; self.startedAt = startedAt; self.endedAt = endedAt
        self.arguments = arguments; self.output = output; self.isError = isError
        self.precedingMessageID = precedingMessageID
    }
}

enum ConversationFeedItem: Identifiable, Sendable, Equatable {
    case message(AgentMessage)
    case activity(ToolActivity)

    var id: String {
        switch self {
        case .message(let message): "message:\(message.id.uuidString)"
        case .activity(let activity): "tool:\(activity.id)"
        }
    }
    var date: Date {
        switch self {
        case .message(let message): message.createdAt
        case .activity(let activity): activity.startedAt
        }
    }

    static func latestActionMessageIDs(in feed: [Self], isAssistantStreaming: Bool = false) -> Set<UUID> {
        var roles = Set<AgentRole>()
        var result = Set<UUID>()
        for case .message(let message) in feed.reversed() {
            guard message.role == .user || message.role == .assistant,
                  roles.insert(message.role).inserted else { continue }
            if message.role == .assistant && isAssistantStreaming { continue }
            result.insert(message.id)
            if roles.count == 2 { break }
        }
        return result
    }

    static func merge(messages: [AgentMessage], activities: [ToolActivity]) -> [Self] {
        var seen = Set<String>()
        let messageIDs = Set(messages.map(\.id))
        let orderedActivities = activities.enumerated().sorted { lhs, rhs in
            if lhs.element.startedAt == rhs.element.startedAt { return lhs.offset < rhs.offset }
            return lhs.element.startedAt < rhs.element.startedAt
        }.map { $0.element }
        let anchoredActivities = orderedActivities.filter { activity in
            activity.precedingMessageID.map { messageIDs.contains($0) } ?? false
        }
        let anchored = Dictionary(grouping: anchoredActivities, by: { $0.precedingMessageID! })
        let unanchored = orderedActivities.filter { activity in
            activity.precedingMessageID.map { !messageIDs.contains($0) } ?? true
        }
        var output: [Self] = []
        var legacyIndex = 0
        // The repository stores messages in admitted event order. Model clocks
        // and delayed host processing must never reorder that sequence.
        for message in messages {
            let item = Self.message(message)
            guard seen.insert(item.id).inserted else { continue }
            while legacyIndex < unanchored.count, unanchored[legacyIndex].startedAt < message.createdAt {
                let activityItem = Self.activity(unanchored[legacyIndex])
                if seen.insert(activityItem.id).inserted { output.append(activityItem) }
                legacyIndex += 1
            }
            output.append(item)
            for activity in anchored[message.id] ?? [] {
                let activityItem = Self.activity(activity)
                if seen.insert(activityItem.id).inserted { output.append(activityItem) }
            }
        }
        for activity in unanchored.dropFirst(legacyIndex) {
            let item = Self.activity(activity)
            if seen.insert(item.id).inserted { output.append(item) }
        }
        return output
    }
}

enum DeviceToolPresentation {
    static func activityTitle(for activity: ToolActivity) -> String {
        if activity.isError {
            guard let operation = title(for: activity.name) else {
                return String(localized: "chat.activity.failed", table: "Chat")
            }
            return String(localized: "chat.activity.failed \(operation)", table: "Chat")
        }
        let key: String.LocalizationValue
        if activity.isRunning {
            key = switch activity.name {
            case "device_screenshot": "chat.activity.observing"
            case "device_list_apps": "chat.activity.listingApps"
            case "device_tap": "chat.activity.tapping"
            case "device_swipe": "chat.activity.swiping"
            case "device_type_text": "chat.activity.typing"
            case "device_launch_app": "chat.activity.launchingApp"
            case "device_home": "chat.activity.goingHome"
            case "device_press_key": "chat.activity.pressingKey"
            default: "chat.activity.running"
            }
        } else {
            key = switch activity.name {
            case "device_screenshot": "chat.activity.observedImage"
            case "device_list_apps": "chat.activity.listedApps"
            case "device_tap": "chat.activity.tapped"
            case "device_swipe": "chat.activity.swiped"
            case "device_type_text": "chat.activity.typed"
            case "device_launch_app": "chat.activity.sentAppLaunch"
            case "device_home": "chat.activity.sentHome"
            case "device_press_key": "chat.activity.pressedKey"
            default: "chat.activity.finished"
            }
        }
        return String(localized: key, table: "Chat")
    }

    static func title(for name: String) -> String? {
        switch name {
        case "device_screenshot": String(localized: "scope.observe")
        case "device_list_apps": String(localized: "tool.listApps")
        case "device_tap": String(localized: "tool.tap")
        case "device_swipe": String(localized: "tool.swipe")
        case "device_type_text": String(localized: "tool.typeText")
        case "device_launch_app": String(localized: "tool.launchApp")
        case "device_home": String(localized: "tool.home")
        case "device_press_key": String(localized: "tool.pressKey")
        default: nil
        }
    }
}

enum ToolActivityFormatting {
    /// Hide credential fields even if a future tool supplies them as arguments.
    /// Actual commands, paths and ordinary parameters remain available to inspect.
    static func arguments(_ value: AgentJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(redacted(value)), let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(8_192))
    }

    private static func redacted(_ value: AgentJSONValue) -> AgentJSONValue {
        switch value {
        case .object(let object):
            var output = object.mapValues(redacted)
            for key in object.keys {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if ["apikey", "password", "authorization", "accesstoken", "refreshtoken", "secret"].contains(normalized) {
                    output[key] = .string("[redacted]")
                }
            }
            return .object(output)
        case .array(let values): return .array(values.map(redacted))
        default: return value
        }
    }
}
