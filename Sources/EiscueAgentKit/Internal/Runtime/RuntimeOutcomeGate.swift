import PiDurableKit

/// Pi terminates a round only if every result requests it, and logs ordinary hook
/// errors without stopping. Abort the owning generation after its results commit,
/// so an earlier successful tool cannot authorize another model request.
actor RuntimeOutcomeGate {
    private var harness: Harness?
    func attach(_ harness: Harness) { self.harness = harness }
    func detach() { harness = nil }

    private func stop(_ taskID: TaskID) async throws {
        guard let harness else { throw AgentError.runtime("The runtime stop gate is unavailable.") }
        try await harness.abortTask(taskID)
    }

    nonisolated func runtimeExtension(budget: RunBudget) -> Extension {
        Extension("eiscue-outcome-gate", hooks: [
            .afterTools { _, _, context in
                if await budget.terminalCause != nil { try await self.stop(context.taskId) }
            },
            .beforeRequest { _, context in
                if await budget.terminalCause != nil { try await self.stop(context.taskId) }
                return nil
            },
        ])
    }
}
