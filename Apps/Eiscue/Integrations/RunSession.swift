import EiscueAgentKit
import EiscueDeviceCore
import Foundation
import Observation

/// A run owns its engine and device until its journal and cleanup have settled.
@MainActor @Observable
final class RunSession {
    enum Phase { case preparing, running, stopping, finishing, ended(RunRecord) }
    let id: UUID
    let scope: TaskScope
    var record: RunRecord {
        didSet { if oldValue.activities != record.activities { activityRevision &+= 1 } }
    }
    private(set) var activityRevision = 0
    var streamingText = ""
    var currentTool = ""
    var tools: DeviceToolSession?
    var isCancelling = false
    var isReceivingResponse = false
    var lastTaskPresentation: TaskStatusPresentation?
    let lease: DeviceLease?
    var device: DeviceClient? { lease?.client }
    private(set) var engine: AgentClient?
    private(set) var phase: Phase = .preparing
    private(set) var stopCause: StopCause?
    var preparation: Task<Void, Error>?
    var stopCleanup: Task<Void, Never>?
    var completion: Task<RunRecord, Never>!

    init(record: RunRecord, lease: DeviceLease?) {
        id = record.id; scope = record.scope; self.record = record; self.lease = lease
    }
    func bind(engine: AgentClient) { precondition(self.engine == nil); self.engine = engine }
    func transition(to phase: Phase) { self.phase = phase }
    func requestStop(_ reason: StopCause) {
        // Cancellation describes the request to stop; later delivery uncertainty
        // describes the action itself and must remain visible to the user.
        if case .outcomeUnknown(let name) = reason {
            if case .outcomeUnknown(let existing) = stopCause, name.isEmpty, !existing.isEmpty {} else { stopCause = reason }
        } else if stopCause == nil { stopCause = reason }
        record.stopCause = stopCause
        phase = .stopping
        preparation?.cancel()
    }
}
