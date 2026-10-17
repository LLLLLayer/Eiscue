import EiscueAgentKit
import Foundation

@MainActor
protocol RunBackgroundExecuting: AnyObject {
    var isExecuting: Bool { get }
    func register() throws
    func begin(taskID: UUID, title: String, subtitle: String, totalUnitCount: Int64,
               onExpiration: @escaping @Sendable () -> Void) async throws
    @discardableResult func update(taskID: UUID, completedUnitCount: Int64, totalUnitCount: Int64,
                                   title: String?, subtitle: String?) -> Bool
    @discardableResult func end(taskID: UUID, success: Bool) -> Bool
}
extension RunBackgroundExecuting {
    func begin(taskID: UUID, title: String, totalUnitCount: Int64,
               onExpiration: @escaping @Sendable () -> Void) async throws {
        try await begin(taskID: taskID, title: title, subtitle: String(localized: "background.running", table: "Runtime"), totalUnitCount: totalUnitCount, onExpiration: onExpiration)
    }
    @discardableResult func update(taskID: UUID, completedUnitCount: Int64, totalUnitCount: Int64, subtitle: String? = nil) -> Bool {
        update(taskID: taskID, completedUnitCount: completedUnitCount, totalUnitCount: totalUnitCount, title: nil, subtitle: subtitle)
    }
}
extension BackgroundExecution: RunBackgroundExecuting {}

@MainActor
protocol RunNotifying: AnyObject {
    var isEnabled: Bool { get }
    var isRequestingAuthorization: Bool { get }
    var authorizationDescription: String { get }
    var lastError: String? { get }
    func refreshAuthorization() async
    func setEnabled(_ enabled: Bool) async
    func notify(runID: UUID, state: RunState, systemActivityUpdated: Bool) async
}
extension TaskNotificationManager: RunNotifying {}

typealias AgentFactory = @MainActor (AgentConfiguration?, URL, [AgentTool]) -> AgentClient
