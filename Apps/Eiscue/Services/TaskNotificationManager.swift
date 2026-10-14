import Foundation
import Observation
import UIKit
import UserNotifications

/// Optional, local terminal-state notifications when no system activity received
/// the result. Live task progress belongs to BGContinuedProcessingTask.
@MainActor
@Observable
final class TaskNotificationManager {
    private(set) var isEnabled: Bool
    private(set) var isRequestingAuthorization = false
    private(set) var authorizationDescription = String(localized: "notifications.authorization.unchecked", table: "Connections")
    private(set) var lastError: String?

    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let client: any TaskNotificationClient
    @ObservationIgnored private let isApplicationForeground: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var scheduledRunIDs: [String]
    @ObservationIgnored private var inFlightRunIDs: Set<String> = []

    private static let enabledKey = "eiscue.taskNotifications.enabled"
    private static let scheduledRunsKey = "eiscue.taskNotifications.scheduledRuns"
    private static let identifierPrefix = "eiscue.task-status."
    // Retain bounded, opaque IDs across App launches, never conversation content.
    private static let historyLimit = 256

    init(
        preferences: UserDefaults,
        client: any TaskNotificationClient = SystemTaskNotificationClient(),
        isApplicationForeground: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState != .background
        }
    ) {
        self.preferences = preferences
        self.client = client
        self.isApplicationForeground = isApplicationForeground
        isEnabled = preferences.bool(forKey: Self.enabledKey)
        scheduledRunIDs = Array(
            (preferences.stringArray(forKey: Self.scheduledRunsKey) ?? []).suffix(Self.historyLimit)
        )
    }

    /// Reads system settings only. Never asks for permission or opens Settings.
    func refreshAuthorization() async {
        let token = generation
        let authorization = await client.authorizationStatus()
        guard token == generation, !isRequestingAuthorization else { return }
        applyAuthorization(authorization)
    }

    /// Only an explicit user action may call this with `true`.
    func setEnabled(_ enabled: Bool) async {
        if !enabled {
            generation = UUID()
            setPreference(false)
            lastError = nil
            let runIDs = Set(scheduledRunIDs).union(inFlightRunIDs)
            removeNotifications(for: Array(runIDs))
            return
        }
        guard !isRequestingAuthorization else { return }
        let token = UUID()
        generation = token
        lastError = nil

        var authorization = await client.authorizationStatus()
        guard token == generation, !Task.isCancelled else { return }
        if authorization == .notDetermined || authorization == .provisional {
            isRequestingAuthorization = true
            do {
                let granted = try await client.requestAuthorization()
                authorization = await client.authorizationStatus()
                isRequestingAuthorization = false
                guard token == generation, !Task.isCancelled else { return }
                applyAuthorization(authorization)
                guard granted, authorization.canNotify else {
                    setPreference(false)
                    lastError = String(localized: "notifications.error.permission_denied", table: "Connections")
                    return
                }
            } catch {
                isRequestingAuthorization = false
                guard token == generation else { return }
                setPreference(false)
                if !(error is CancellationError) {
                    lastError = String(localized: "notifications.error.authorization_failed", table: "Connections")
                }
                return
            }
        } else {
            applyAuthorization(authorization)
        }
        guard authorization.canNotify else {
            setPreference(false)
            lastError = String(localized: "notifications.error.permission_denied", table: "Connections")
            return
        }
        setPreference(true)
    }

    /// Deduplicates recent runs across App launches. Nonterminal states and
    /// foreground calls are ignored. A system activity already presenting the
    /// result needs no duplicate alert. Payloads contain fixed status text only.
    func notify(runID: UUID, state: RunState, systemActivityUpdated: Bool = false) async {
        guard !systemActivityUpdated, isEnabled, !isApplicationForeground(), !Task.isCancelled,
              let body = Self.body(for: state) else { return }
        let id = runID.uuidString.lowercased()
        guard !scheduledRunIDs.contains(id), !inFlightRunIDs.contains(id) else { return }
        let token = generation
        inFlightRunIDs.insert(id)
        defer { inFlightRunIDs.remove(id) }

        let authorization = await client.authorizationStatus()
        guard token == generation, isEnabled, !Task.isCancelled else { return }
        applyAuthorization(authorization)
        // The App may have returned to the foreground while reading settings.
        guard authorization.canNotify, isEnabled, !isApplicationForeground() else { return }

        let request = TaskStatusNotification(
            identifier: Self.identifierPrefix + id,
            title: String(localized: "notifications.task.title", table: "Connections"),
            body: body
        )
        do {
            try await client.add(request)
            // Acceptance consumes this run's notification even if a concurrent
            // opt-out immediately removes it; enabling does not replay old runs.
            scheduledRunIDs.append(id)
            scheduledRunIDs = Array(scheduledRunIDs.suffix(Self.historyLimit))
            preferences.set(scheduledRunIDs, forKey: Self.scheduledRunsKey)
            guard token == generation, isEnabled, !isApplicationForeground(), !Task.isCancelled else {
                // Disabling may have raced with the system's add completion.
                removeNotifications(for: [id])
                return
            }
        } catch {
            if token == generation, isEnabled, !(error is CancellationError) {
                lastError = String(localized: "notifications.error.submission_failed", table: "Connections")
            }
        }
    }

    private func setPreference(_ enabled: Bool) {
        isEnabled = enabled
        preferences.set(enabled, forKey: Self.enabledKey)
    }

    private func applyAuthorization(_ authorization: TaskNotificationAuthorization) {
        authorizationDescription = authorization.description
        if !authorization.canNotify, isEnabled {
            // Permission revocation also invalidates any outstanding delivery.
            generation = UUID()
            setPreference(false)
        }
    }

    private func removeNotifications(for runIDs: [String]) {
        guard !runIDs.isEmpty else { return }
        let identifiers = runIDs.map { Self.identifierPrefix + $0 }
        client.removePendingRequests(withIdentifiers: identifiers)
        client.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private static func body(for state: RunState) -> String? {
        switch state {
        case .completed: String(localized: "notifications.task.completed", table: "Connections")
        case .paused: String(localized: "notifications.task.paused", table: "Connections")
        case .interrupted: String(localized: "notifications.task.interrupted", table: "Connections")
        case .failed: String(localized: "notifications.task.failed", table: "Connections")
        case .preparing, .running: nil
        }
    }
}

enum TaskNotificationAuthorization: Sendable, Equatable {
    case notDetermined, denied, authorized, provisional, ephemeral, unknown

    var canNotify: Bool {
        self == .authorized || self == .provisional || self == .ephemeral
    }

    var description: String {
        switch self {
        case .notDetermined: String(localized: "notifications.authorization.not_determined", table: "Connections")
        case .denied: String(localized: "notifications.authorization.denied", table: "Connections")
        case .authorized: String(localized: "notifications.authorization.authorized", table: "Connections")
        case .provisional: String(localized: "notifications.authorization.provisional", table: "Connections")
        case .ephemeral: String(localized: "notifications.authorization.ephemeral", table: "Connections")
        case .unknown: String(localized: "notifications.authorization.unknown", table: "Connections")
        }
    }
}

struct TaskStatusNotification: Sendable, Equatable {
    let identifier: String
    let title: String
    let body: String
}

/// Isolated from the system notification center so tests cannot prompt users.
@MainActor
protocol TaskNotificationClient: AnyObject {
    func authorizationStatus() async -> TaskNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func add(_ request: TaskStatusNotification) async throws
    func removePendingRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
final class SystemTaskNotificationClient: TaskNotificationClient {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> TaskNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: TaskStatusNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
