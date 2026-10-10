import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class TaskNotificationManagerTests: XCTestCase {
    func testDefaultOptOutAndRefreshNeverRequestPermission() async {
        let client = RecordingNotificationClient()
        let manager = makeManager(client: client)

        await manager.notify(runID: UUID(), state: .completed)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(client.statusReads, 0)
        await manager.refreshAuthorization()
        XCTAssertEqual(client.statusReads, 1)
        XCTAssertEqual(client.authorizationRequests, 0)
        XCTAssertTrue(client.added.isEmpty)
    }

    func testExplicitEnableHandlesDenialWithoutClaimingEnabledOrRepeatingPrompt() async {
        let client = RecordingNotificationClient()
        client.grantAuthorization = false
        let manager = makeManager(client: client)

        await manager.setEnabled(true)
        XCTAssertEqual(client.authorizationRequests, 1)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(manager.isRequestingAuthorization)
        XCTAssertNotNil(manager.lastError)

        await manager.setEnabled(true)
        XCTAssertEqual(client.authorizationRequests, 1)
        XCTAssertFalse(manager.isEnabled)
        await manager.notify(runID: UUID(), state: .failed)
        XCTAssertTrue(client.added.isEmpty)
    }

    func testOnlyTerminalStatesUseFixedLocalizedTextAndDeduplicateAcrossLaunches() async {
        let client = RecordingNotificationClient()
        client.status = .authorized
        let preferences = makePreferences()
        let manager = makeManager(client: client, preferences: preferences)
        await manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(client.authorizationRequests, 0)

        await manager.notify(runID: UUID(), state: .preparing)
        await manager.notify(runID: UUID(), state: .running)
        let completedID = UUID()
        let interruptedID = UUID()
        await manager.notify(runID: completedID, state: .completed)
        await manager.notify(runID: interruptedID, state: .interrupted)
        await manager.notify(runID: UUID(), state: .failed)
        await manager.notify(runID: completedID, state: .completed)
        await manager.notify(runID: interruptedID, state: .failed)

        XCTAssertEqual(client.added.count, 3)
        XCTAssertEqual(client.added.map(\.title), Array(repeating: localized("notifications.task.title"), count: 3))
        XCTAssertEqual(client.added.map(\.body), [
            localized("notifications.task.completed"),
            localized("notifications.task.interrupted"),
            localized("notifications.task.failed"),
        ])
        XCTAssertEqual(client.added.first?.identifier, "eiscue.task-status." + completedID.uuidString.lowercased())
        let relaunched = makeManager(client: client, preferences: preferences)
        await relaunched.notify(runID: completedID, state: .completed)
        XCTAssertEqual(client.added.count, 3)
    }

    func testRevokedSystemPermissionDisablesDeliveryAndPersistsOptOut() async {
        let client = RecordingNotificationClient()
        client.status = .authorized
        let preferences = makePreferences()
        let manager = makeManager(client: client, preferences: preferences)
        await manager.setEnabled(true)
        client.status = .denied

        await manager.notify(runID: UUID(), state: .completed)

        XCTAssertTrue(client.added.isEmpty)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(manager.authorizationDescription, localized("notifications.authorization.denied"))
        XCTAssertFalse(makeManager(client: client, preferences: preferences).isEnabled)
        XCTAssertEqual(client.authorizationRequests, 0)
    }

    func testRefreshObservesRevocationWithoutRequestingAuthorization() async {
        let client = RecordingNotificationClient()
        client.status = .authorized
        let manager = makeManager(client: client)
        await manager.setEnabled(true)
        client.status = .denied

        await manager.refreshAuthorization()

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(client.authorizationRequests, 0)
        XCTAssertTrue(client.added.isEmpty)
    }

    func testForegroundReturnDuringPermissionReadSuppressesNotification() async {
        let client = RecordingNotificationClient()
        client.status = .authorized
        var isActive = false
        let manager = TaskNotificationManager(
            preferences: makePreferences(), client: client, isApplicationForeground: { isActive }
        )
        await manager.setEnabled(true)
        client.onStatusRead = { isActive = true }

        await manager.notify(runID: UUID(), state: .completed)

        XCTAssertTrue(client.added.isEmpty)
        let reads = client.statusReads
        await manager.notify(runID: UUID(), state: .completed)
        XCTAssertEqual(client.statusReads, reads, "Already-foreground calls must be ignored before reading permission.")
    }

    func testOptOutDuringAuthorizationPreventsLateEnable() async {
        let client = RecordingNotificationClient()
        client.pauseAuthorization = true
        let suspended = expectation(description: "Authorization request suspended")
        client.onAuthorizationSuspended = { suspended.fulfill() }
        let manager = makeManager(client: client)
        let enable = Task { await manager.setEnabled(true) }
        await fulfillment(of: [suspended], timeout: 1)
        XCTAssertTrue(manager.isRequestingAuthorization)

        await manager.setEnabled(false)
        client.finishAuthorization(granted: true)
        await enable.value

        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(manager.isRequestingAuthorization)
        await manager.notify(runID: UUID(), state: .completed)
        XCTAssertTrue(client.added.isEmpty)
    }

    func testConcurrentDuplicateAndOptOutDuringAddCannotLeaveOrReplayNotification() async {
        let client = RecordingNotificationClient()
        client.status = .authorized
        let manager = makeManager(client: client)
        await manager.setEnabled(true)
        client.pauseAdd = true
        let suspended = expectation(description: "Notification submission suspended")
        client.onAddSuspended = { suspended.fulfill() }
        let runID = UUID()
        let delivery = Task { await manager.notify(runID: runID, state: .completed) }
        await fulfillment(of: [suspended], timeout: 1)

        await manager.notify(runID: runID, state: .failed)
        XCTAssertEqual(client.added.count, 1)
        await manager.setEnabled(false)
        client.finishAdd()
        await delivery.value

        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertTrue(client.delivered.isEmpty)
        await manager.setEnabled(true)
        await manager.notify(runID: runID, state: .completed)
        XCTAssertEqual(client.added.count, 1, "A consumed terminal notification must not replay after enabling.")
    }

    private func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Connections")
    }

    private func makeManager(
        client: RecordingNotificationClient, preferences: UserDefaults? = nil
    ) -> TaskNotificationManager {
        TaskNotificationManager(
            preferences: preferences ?? makePreferences(), client: client, isApplicationForeground: { false }
        )
    }

    private func makePreferences() -> UserDefaults {
        let suiteName = "org.eiscue.app.tests.notifications." + UUID().uuidString
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return UserDefaults(suiteName: suiteName)!
    }
}

@MainActor
private final class RecordingNotificationClient: TaskNotificationClient {
    var status: TaskNotificationAuthorization = .notDetermined
    var grantAuthorization = true
    var pauseAuthorization = false
    var pauseAdd = false
    var onStatusRead: (() -> Void)?
    var onAuthorizationSuspended: (() -> Void)?
    var onAddSuspended: (() -> Void)?
    private(set) var statusReads = 0
    private(set) var authorizationRequests = 0
    private(set) var added: [TaskStatusNotification] = []
    private(set) var pending: Set<String> = []
    private(set) var delivered: Set<String> = []
    private var authorizationContinuation: CheckedContinuation<Bool, any Error>?
    private var addContinuation: CheckedContinuation<Void, any Error>?

    func authorizationStatus() async -> TaskNotificationAuthorization {
        statusReads += 1
        onStatusRead?()
        return status
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if pauseAuthorization {
            return try await withCheckedThrowingContinuation { continuation in
                authorizationContinuation = continuation
                onAuthorizationSuspended?()
            }
        }
        status = grantAuthorization ? .authorized : .denied
        return grantAuthorization
    }

    func add(_ request: TaskStatusNotification) async throws {
        added.append(request)
        if pauseAdd {
            try await withCheckedThrowingContinuation { continuation in
                addContinuation = continuation
                onAddSuspended?()
            }
        }
        pending.insert(request.identifier)
        delivered.insert(request.identifier)
    }

    func finishAuthorization(granted: Bool) {
        status = granted ? .authorized : .denied
        authorizationContinuation?.resume(returning: granted)
        authorizationContinuation = nil
    }

    func finishAdd() {
        pauseAdd = false
        addContinuation?.resume()
        addContinuation = nil
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        pending.subtract(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        delivered.subtract(identifiers)
    }
}
