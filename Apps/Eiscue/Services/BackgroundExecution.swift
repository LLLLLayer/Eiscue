import BackgroundTasks
import Foundation
import UIKit

/// Owns one user-initiated continued-processing task for the entire application.
/// Call `register()` during App startup, then await `begin` before relying on
/// background execution. Submission failure does not silently fall back.
@MainActor
final class BackgroundExecution {
    static let shared = BackgroundExecution()

    enum Failure: Error, LocalizedError {
        case registrationFailed
        case notRegistered
        case alreadyRunning
        case foregroundRequired
        case invalidProgress
        case launchTimedOut
        case cancelledLaunchPending
        case expired
        case unexpectedTask

        var errorDescription: String? {
            switch self {
            case .registrationFailed:
                String(localized: "background.registration_failed", table: "Runtime")
            case .notRegistered:
                String(localized: "background.not_registered", table: "Runtime")
            case .alreadyRunning:
                String(localized: "background.already_running", table: "Runtime")
            case .foregroundRequired:
                String(localized: "background.foreground_required", table: "Runtime")
            case .invalidProgress:
                String(localized: "background.invalid_progress", table: "Runtime")
            case .launchTimedOut:
                String(localized: "background.launch_timeout", table: "Runtime")
            case .cancelledLaunchPending:
                String(localized: "background.pending_launch", table: "Runtime")
            case .expired:
                String(localized: "background.expired", table: "Runtime")
            case .unexpectedTask:
                String(localized: "background.unexpected_task", table: "Runtime")
            }
        }
    }

    /// Keep Info.plist's BGTaskSchedulerPermittedIdentifiers in sync with this.
    let identifier: String
    private(set) var isRegistered = false
    var activeTaskID: UUID? { run?.taskID }
    var isExecuting: Bool { run?.lease?.isActive == true }

    private struct Run {
        let taskID: UUID
        let token: UUID
        var status: BackgroundTaskStatus
        let onExpiration: @Sendable () -> Void
        var continuation: CheckedContinuation<Void, any Error>?
        var lease: ContinuedTaskLease?
    }

    private let scheduler = BGTaskScheduler.shared
    private var run: Run?
    private var launchTimeout: Task<Void, Never>?
    // A static identifier cannot distinguish a cancelled, late launch from a
    // new request. Quarantine it until the late handler arrives (or App restart).
    private var cancelledLaunchPending = false

    private init() {
        identifier = (Bundle.main.bundleIdentifier ?? "org.eiscue.app")
            + ".agent.continued-processing"
    }

    /// Idempotent. The singleton prevents duplicate identifier registration,
    /// which BGTaskScheduler treats as a fatal programming error.
    func register() throws {
        guard !isRegistered else { return }
        isRegistered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) {
            [weak self] task in
            // The scheduler dispatches this handler on the explicitly supplied
            // main queue; no BGTask crosses a Swift actor boundary.
            MainActor.assumeIsolated {
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.didLaunch(task)
            }
        }
        guard isRegistered else { throw Failure.registrationFailed }
    }

    /// Returns only after the system invokes the continued-task launch handler.
    /// `onExpiration` runs immediately on the system callback queue; keep it
    /// short and thread-safe (for example, cancel a Swift Task). Hop to MainActor
    /// inside the closure if it also needs to change UI state.
    func begin(
        taskID: UUID,
        title: String,
        subtitle: String = String(localized: "background.running", table: "Runtime"),
        totalUnitCount: Int64 = 1,
        onExpiration: @escaping @Sendable () -> Void
    ) async throws {
        guard isRegistered else { throw Failure.notRegistered }
        guard !cancelledLaunchPending else { throw Failure.cancelledLaunchPending }
        guard run == nil else { throw Failure.alreadyRunning }
        guard totalUnitCount > 0 else { throw Failure.invalidProgress }
        guard UIApplication.shared.applicationState == .active else {
            throw Failure.foregroundRequired
        }
        try Task.checkCancellation()
        let token = UUID()
        let initialStatus = BackgroundTaskStatus(
            title: title, subtitle: subtitle, totalUnitCount: totalUnitCount
        )

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    // Cancellation can occur before this synchronous body starts.
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    run = Run(
                        taskID: taskID,
                        token: token,
                        status: initialStatus,
                        onExpiration: onExpiration,
                        continuation: continuation
                    )
                    let request = BGContinuedProcessingTaskRequest(
                        identifier: identifier, title: initialStatus.title, subtitle: initialStatus.subtitle
                    )
                    request.strategy = .fail
                    do {
                        try scheduler.submit(request)
                        launchTimeout = Task { @MainActor [weak self] in
                            do {
                                try await Task.sleep(for: .seconds(10))
                            } catch {
                                return
                            }
                            self?.abandonLaunch(token: token, error: Failure.launchTimedOut)
                        }
                    } catch {
                        // No accepted request exists after a submission failure.
                        run = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancel(token: token)
                }
            }
            try Task.checkCancellation()
            guard run?.token == token, run?.lease?.isActive == true else {
                throw Failure.expired
            }
        } catch {
            cancel(token: token)
            throw error
        }
    }

    /// Report actual completed work; no synthetic timer advances the progress.
    /// Stale updates for a previous task and invalid counts are ignored.
    /// Accepted updates are retained even while the launch handler is pending.
    @discardableResult
    func update(
        taskID: UUID,
        completedUnitCount: Int64,
        totalUnitCount: Int64,
        title: String? = nil,
        subtitle: String? = nil
    ) -> Bool {
        guard var current = run, current.taskID == taskID else { return false }
        guard current.status.update(
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            title: title,
            subtitle: subtitle
        ) else { return false }
        if let lease = current.lease, !lease.update(status: current.status) { return false }
        run = current
        return true
    }

    /// Call after completion, failure, or an in-App stop. Repeated/stale calls
    /// are harmless. The host remains responsible for stopping its own work.
    func end(taskID: UUID, success: Bool) {
        guard let current = run, current.taskID == taskID else { return }
        if let lease = current.lease {
            run = nil
            lease.finish(success: success)
        } else {
            abandonLaunch(token: current.token, error: CancellationError())
        }
    }

    private func didLaunch(_ task: BGTask) {
        if cancelledLaunchPending {
            cancelledLaunchPending = false
            task.setTaskCompleted(success: false)
            return
        }
        guard let current = run, current.lease == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        guard let continued = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            launchTimeout?.cancel()
            launchTimeout = nil
            run = nil
            current.continuation?.resume(throwing: Failure.unexpectedTask)
            return
        }
        launchTimeout?.cancel()
        launchTimeout = nil
        let token = current.token
        let lease = ContinuedTaskLease(
            task: continued,
            onExpiration: current.onExpiration,
            onExpired: { [weak self] in
                Task { @MainActor in
                    self?.didExpire(token: token)
                }
            }
        )
        run?.lease = lease
        run?.continuation = nil
        lease.armExpirationHandler()
        // A request's text describes the pending task. Reapply the latest
        // complete status to the running activity before work resumes.
        _ = lease.update(status: current.status)
        current.continuation?.resume()
    }

    private func didExpire(token: UUID) {
        guard run?.token == token else { return }
        run = nil
    }

    private func cancel(token: UUID) {
        guard let current = run, current.token == token else { return }
        if current.lease != nil {
            end(taskID: current.taskID, success: false)
        } else {
            abandonLaunch(token: token, error: CancellationError())
        }
    }

    private func abandonLaunch(token: UUID, error: any Error) {
        guard let current = run, current.token == token, current.lease == nil else { return }
        run = nil
        launchTimeout?.cancel()
        launchTimeout = nil
        cancelledLaunchPending = true
        scheduler.cancel(taskRequestWithIdentifier: identifier)
        current.continuation?.resume(throwing: error)
    }
}

/// The latest accepted display state, including updates before system launch.
/// Text comes from fixed localized app states, never task or device contents.
struct BackgroundTaskStatus: Equatable, Sendable {
    private(set) var title: String
    private(set) var subtitle: String
    private(set) var completedUnitCount: Int64 = 0
    private(set) var totalUnitCount: Int64

    init(title: String, subtitle: String, totalUnitCount: Int64) {
        self.title = Self.normalizedTitle(title)
        self.subtitle = Self.normalizedSubtitle(subtitle)
        self.totalUnitCount = totalUnitCount
    }

    mutating func update(
        completedUnitCount: Int64,
        totalUnitCount: Int64,
        title: String?,
        subtitle: String?
    ) -> Bool {
        guard totalUnitCount > 0,
              completedUnitCount >= 0,
              completedUnitCount <= totalUnitCount else { return false }
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        if let title { self.title = Self.normalizedTitle(title) }
        if let subtitle { self.subtitle = Self.normalizedSubtitle(subtitle) }
        return true
    }

    private static func normalizedTitle(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
            ? String(localized: "background.status.title", defaultValue: "Eiscue is working", table: "BackgroundStatus")
            : text
    }

    private static func normalizedSubtitle(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
            ? String(localized: "background.status.running", defaultValue: "Task in progress", table: "BackgroundStatus")
            : text
    }
}

/// BGTask expiration may arrive off MainActor. The lock serializes access to
/// the task and completion flag, and only one caller can complete the task.
private final class ContinuedTaskLease: @unchecked Sendable {
    private let task: BGContinuedProcessingTask
    private let lock = NSLock()
    private var completed = false
    private var onExpiration: (@Sendable () -> Void)?
    private let onExpired: @Sendable () -> Void

    init(
        task: BGContinuedProcessingTask,
        onExpiration: @escaping @Sendable () -> Void,
        onExpired: @escaping @Sendable () -> Void
    ) {
        self.task = task
        self.onExpiration = onExpiration
        self.onExpired = onExpired
    }

    var isActive: Bool { lock.withLock { !completed } }

    func armExpirationHandler() {
        task.expirationHandler = { [weak self] in self?.expire() }
    }

    func update(status: BackgroundTaskStatus) -> Bool {
        lock.withLock {
            guard !completed else { return false }
            task.progress.totalUnitCount = status.totalUnitCount
            task.progress.completedUnitCount = status.completedUnitCount
            task.updateTitle(status.title, subtitle: status.subtitle)
            return true
        }
    }

    func finish(success: Bool) {
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            onExpiration = nil
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            return true
        }
        guard shouldComplete else { return }
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }

    private func expire() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            let callback = onExpiration
            onExpiration = nil
            return callback
        }
        guard let callback else { return }
        callback()
        task.expirationHandler = nil
        task.setTaskCompleted(success: false)
        onExpired()
    }
}
