#if DEBUG
import EiscueAgentKit
import Foundation
import UIKit

extension AppModel {
    func installLongConversationFixture() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--long-conversation-fixture") else { return }
        let messages = (0..<300).map { index in
            AgentMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                         text: index == 299 ? "LATEST_HISTORY_MESSAGE" : "History entry \(index)\n\nA paragraph for scrolling through a long conversation.",
                         createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        let conversation = Conversation(title: "Long history fixture", messages: messages)
        conversations = [conversation]; runs = []; selectedConversationID = conversation.id
        if ProcessInfo.processInfo.arguments.contains("--long-sidebar-fixture") {
            conversations += (0..<40).map { index in
                Conversation(title: String(format: "Sidebar history %02d", index),
                             createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)))
            }
        }
    }

    /// Exercises the real transcript with deterministic tool output, without
    /// connecting a device, requesting a model or persisting screenshot bytes.
    func installToolImagePreviewFixture() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--tool-image-preview-fixture") else { return }
        appearance = ProcessInfo.processInfo.arguments.contains("--tool-image-preview-dark") ? .dark : .light
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let user = AgentMessage(role: .user, text: "查看当前屏幕", createdAt: time)
        let reply = AgentMessage(role: .assistant, text: "屏幕显示的是外观设置。", createdAt: time.addingTimeInterval(10))
        let conversation = Conversation(title: "Image preview fixture", messages: [user, reply])
        var record = RunRecord(id: UUID(), conversationID: conversation.id, requestID: user.id,
                               startedAt: time, scope: .observe, model: "UI fixture", skill: nil,
                               state: .completed, endedAt: time.addingTimeInterval(10), detail: "", events: [])
        record.activities = [
            ToolActivity(id: "preview:image", name: DeviceToolSpec.screenshot.rawValue, startedAt: time.addingTimeInterval(1), endedAt: time.addingTimeInterval(2),
                         output: "frameId=11111111-1111-1111-1111-111111111111; width=390; height=844;", precedingMessageID: user.id),
            ToolActivity(id: "preview:text", name: DeviceToolSpec.listApplications.rawValue, startedAt: time.addingTimeInterval(3), endedAt: time.addingTimeInterval(4),
                         output: "INTERNAL_TEXT_OUTPUT", precedingMessageID: user.id),
            ToolActivity(id: "preview:error", name: DeviceToolSpec.screenshot.rawValue, startedAt: time.addingTimeInterval(5), endedAt: time.addingTimeInterval(6),
                         output: "INTERNAL_ERROR_OUTPUT", isError: true, precedingMessageID: user.id),
            ToolActivity(id: "preview:old", name: DeviceToolSpec.screenshot.rawValue, startedAt: time.addingTimeInterval(7), endedAt: time.addingTimeInterval(8),
                         output: "frameId=old-metadata-only; width=390; height=844;", precedingMessageID: user.id)
        ]
        toolImagePreviews.removeAll()
        let image = Self.toolPreviewFixtureImage()
        toolImagePreviews.record(AgentToolCompletion(call: .init(id: "image", name: DeviceToolSpec.screenshot.rawValue, arguments: [:]),
                                                    result: .image(image, mimeType: "image/png")),
                                 activityID: "preview:image", conversationID: conversation.id)
        toolImagePreviews.record(AgentToolCompletion(call: .init(id: "error", name: DeviceToolSpec.screenshot.rawValue, arguments: [:]),
                                                    result: .init(content: [.image(data: image, mimeType: "image/png")], isError: true)),
                                 activityID: "preview:error", conversationID: conversation.id)
        toolImagePreviews.markUnavailable(activityID: "preview:old", conversationID: conversation.id)
        if ProcessInfo.processInfo.arguments.contains("--run-tool-detail-fixture") {
            record.activities?.append(ToolActivity(id: "preview:tap", name: DeviceToolSpec.tap.rawValue, startedAt: time.addingTimeInterval(8),
                                                  endedAt: time.addingTimeInterval(9),
                                                  arguments: #"{"frameId":"11111111-1111-1111-1111-111111111111","x":284,"y":525}"#,
                                                  output: "frameId=22222222-2222-2222-2222-222222222222; width=390; height=844;",
                                                  precedingMessageID: user.id))
            toolImagePreviews.record(AgentToolCompletion(call: .init(id: "tap", name: DeviceToolSpec.tap.rawValue, arguments: [:]),
                                                        result: .image(image, mimeType: "image/png")),
                                     activityID: "preview:tap", conversationID: conversation.id)
        }
        conversations = [conversation]; runs = [record]; selectedConversationID = conversation.id
    }

    private static func toolPreviewFixtureImage() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: 390, height: 844)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(white: 0.95, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            let titleStyle: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: UIColor.black]
            ("Display & Brightness" as NSString).draw(at: CGPoint(x: 22, y: 70), withAttributes: titleStyle)
            for (index, title) in ["Light", "Dark"].enumerated() {
                let x = CGFloat(index) * 178 + 24
                let card = CGRect(x: x, y: 155, width: 164, height: 300)
                (index == 0 ? UIColor.white : UIColor(white: 0.08, alpha: 1)).setFill()
                UIBezierPath(roundedRect: card, cornerRadius: 22).fill()
                for row in 0..<4 {
                    (index == 0 ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.25, alpha: 1)).setFill()
                    UIBezierPath(roundedRect: CGRect(x: x + 18, y: 180 + CGFloat(row) * 48, width: 128, height: 32), cornerRadius: 8).fill()
                }
                (title as NSString).draw(at: CGPoint(x: x + 52, y: 476), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
            }
            UIColor.systemBlue.setFill(); UIBezierPath(ovalIn: CGRect(x: 271, y: 512, width: 26, height: 26)).fill()
            ("Brightness" as NSString).draw(at: CGPoint(x: 24, y: 614), withAttributes: titleStyle)
            UIColor(white: 0.75, alpha: 1).setFill(); UIBezierPath(roundedRect: CGRect(x: 24, y: 670, width: 342, height: 8), cornerRadius: 4).fill()
            UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 190, y: 658, width: 32, height: 32)).fill()
        }
    }

    /// Available only to the opt-in local UI fixture. No file is actually read,
    /// edited or executed, and production chat keeps its normal empty tool set.
    static var timelineFixtureTools: [AgentTool] {
        [AgentTool(name: "fixture_read_file", description: "Read the integration fixture document.",
                   parameters: .object(["type": .string("object"),
                                        "properties": .object(["path": .object(["type": .string("string")])]),
                                        "required": .array([.string("path")]),
                                        "additionalProperties": .bool(false)]), mayHaveSideEffects: false) { arguments in
            guard case .object(let values) = arguments else {
                return .error("Unexpected fixture path")
            }
            if values["path"] == .string("pause.txt") {
                throw AgentError.toolExecutionPaused(String(localized: "toolError.noProgress"))
            }
            guard values["path"] == .string("fixture.txt") else { return .error("Unexpected fixture path") }
            return .text("Fixture document content")
        }]
    }
}
#endif
