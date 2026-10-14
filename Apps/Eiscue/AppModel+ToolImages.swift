import EiscueAgentKit
import Foundation

extension AppModel {
    /// Restores only the image returned by this exact durable call, never today's live screen.
    func loadToolImagePreviews(for activity: ToolActivity) async {
        guard toolImagePreviews.state(for: activity.id) == .idle else { return }
        guard !activity.isRunning, !activity.isError, ToolImagePreviewStore.returnsDeviceImage(activity.name),
              let run = ([activeRun].compactMap { $0 } + runs).first(where: {
                  $0.activities?.contains(where: { $0.id == activity.id && $0.name == activity.name }) == true
              }), conversations.contains(where: { $0.id == run.conversationID }) else {
            toolImagePreviews.markUnavailable(activityID: activity.id)
            return
        }
        let prefix = "\(run.id.uuidString):"
        guard activity.id.hasPrefix(prefix) else {
            toolImagePreviews.markUnavailable(activityID: activity.id, conversationID: run.conversationID)
            return
        }
        guard let token = toolImagePreviews.beginLoading(activityID: activity.id, conversationID: run.conversationID) else { return }
        let callID = String(activity.id.dropFirst(prefix.count))
        do {
            let reader = agent ?? AgentClient(storageDirectory: runtimeDirectory)
            let result = try await reader.toolResult(conversationID: run.conversationID, requestID: run.requestID, toolCallID: callID)
            try Task.checkCancellation()
            let matched = result?.call.id == callID && result?.call.name == activity.name ? result : nil
            toolImagePreviews.finishLoading(matched, activityID: activity.id, token: token)
        } catch is CancellationError {
            toolImagePreviews.cancelLoading(activityID: activity.id, token: token)
        } catch AgentError.busy {
            toolImagePreviews.cancelLoading(activityID: activity.id, token: token)
        } catch {
            // Missing or incompatible historical data must not interrupt the current task.
            toolImagePreviews.finishLoading(nil, activityID: activity.id, token: token)
        }
    }
}
