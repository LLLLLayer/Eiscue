import EiscueDeviceCore
import Foundation
import XCTest
@testable import Eiscue

@MainActor final class DeviceSessionTests: XCTestCase {
    func testConnectionAndReleasePublishOneConsistentRouteBackendAndStatus() async throws {
        let fixture = Fixture()
        let ready = try await fixture.session.connect(method: .localVPN, backend: .automatic)
        XCTAssertEqual(ready, fixture.route.readyStatus)
        XCTAssertEqual(fixture.session.activeMethod, .localVPN)
        XCTAssertEqual(fixture.session.activeBackend, .coreDevice)
        XCTAssertEqual(fixture.session.state, .connected(route: .localVPN, backend: .coreDevice, status: ready))
        let releaseID = UUID()
        let confirmed = try await fixture.session.releaseConnection(id: releaseID)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(fixture.session.operationID, releaseID)
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertNil(fixture.session.activeMethod); XCTAssertNil(fixture.session.activeBackend)
        XCTAssertFalse(fixture.session.isTransitioning)
        XCTAssertEqual(fixture.route.connections, [.localVPN]); XCTAssertEqual(fixture.route.disconnects, 1)
    }

    func testAcquisitionIsBlockedDuringConnectionAndRelease() throws {
        let fixture = Fixture()
        let connection = try fixture.session.beginConnection(method: .localVPN, backend: .xcTest)
        XCTAssertThrowsError(try fixture.session.acquire(.run(UUID())))
        XCTAssertTrue(fixture.session.completeConnection(connection, status: fixture.route.readyStatus))
        let release = try fixture.session.beginRelease()
        XCTAssertThrowsError(try fixture.session.acquire(.dictation(UUID())))
        XCTAssertTrue(fixture.session.completeRelease(release, confirmed: true, status: fixture.route.readyStatus))
        XCTAssertNil(fixture.session.activeMethod)
        if case .ready = fixture.session.status { XCTFail("A stale ready cache must not revive a released session.") }
        XCTAssertFalse(fixture.session.isTransitioning)
    }

    func testProgressAppearsForConnectionAndActiveReleaseButNotIdleCleanup() throws {
        let fixture = Fixture()
        let idleRelease = try fixture.session.beginRelease()
        XCTAssertTrue(fixture.session.isTransitioning); XCTAssertFalse(fixture.session.showsConnectionProgress)
        XCTAssertTrue(fixture.session.completeRelease(idleRelease, confirmed: true))
        let id = UUID()
        let connection = try fixture.session.beginConnection(method: .localVPN, backend: .coreDevice, id: id)
        XCTAssertEqual(fixture.session.operationID, id); XCTAssertTrue(fixture.session.showsConnectionProgress)
        XCTAssertTrue(fixture.session.completeConnection(connection, status: fixture.route.readyStatus))
        XCTAssertFalse(fixture.session.showsConnectionProgress)
        let activeRelease = try fixture.session.beginRelease()
        XCTAssertTrue(fixture.session.showsConnectionProgress)
        XCTAssertTrue(fixture.session.completeRelease(activeRelease, confirmed: true))
        XCTAssertFalse(fixture.session.showsConnectionProgress)
    }

    func testReleasingTheOwnerDuringConnectionSettlesWithoutPublishingItsResult() throws {
        let fixture = Fixture(), owner = DeviceSession.Owner.dictation(UUID())
        let lease = try fixture.session.acquire(owner)
        let connection = try fixture.session.beginConnection(method: .localVPN, backend: .coreDevice, owner: owner)
        lease.release()
        XCTAssertFalse(fixture.session.completeConnection(connection, status: fixture.route.readyStatus))
        XCTAssertFalse(fixture.session.isTransitioning); XCTAssertNil(fixture.session.owner)
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertNil(fixture.session.activeMethod); XCTAssertNil(fixture.session.activeBackend)
        let next = try fixture.session.acquire(.setup); next.release()
    }

    func testReadyStatusCannotPublishAConnectionBeforeItsOperationCompletes() throws {
        let fixture = Fixture()
        let connection = try fixture.session.beginConnection(method: .localVPN, backend: .coreDevice)
        XCTAssertTrue(fixture.session.updateStatus(fixture.route.readyStatus, expected: fixture.session.identity))
        if case .ready = fixture.session.status { XCTFail("Only a completed connection can publish readiness.") }
        XCTAssertNil(fixture.session.activeMethod)
        XCTAssertTrue(fixture.session.completeConnection(connection, status: fixture.route.readyStatus))
        let release = try fixture.session.beginRelease()
        XCTAssertTrue(fixture.session.updateStatus(fixture.route.readyStatus, expected: fixture.session.identity))
        if case .ready = fixture.session.status { XCTFail("A stale ready cache cannot outlive a release boundary.") }
        XCTAssertTrue(fixture.session.completeRelease(release, confirmed: true))
    }

    func testSetupRequiresItsOwnSetupLeaseAndBlocksOverlappingTransitions() throws {
        let fixture = Fixture(), id = UUID()
        XCTAssertThrowsError(try fixture.session.beginSetup(owner: .setup))
        let repair = try fixture.session.acquire(.repair)
        XCTAssertThrowsError(try fixture.session.beginSetup(owner: repair.owner))
        repair.release()
        let setup = try fixture.session.acquire(.setup)
        let operation = try fixture.session.beginSetup(owner: setup.owner, id: id)
        XCTAssertEqual(fixture.session.operationID, id)
        XCTAssertTrue(fixture.session.showsConnectionProgress)
        XCTAssertThrowsError(try fixture.session.beginSetup(owner: setup.owner))
        XCTAssertThrowsError(try fixture.session.beginConnection(method: .localVPN, backend: .coreDevice, owner: setup.owner))
        XCTAssertTrue(fixture.session.completeSetup(operation))
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertEqual(fixture.session.owner, .setup)
        setup.release()
    }

    func testSetupRetainsCapturedTransportMetadataWithoutRestoringAnOldReadyStatus() async throws {
        let fixture = Fixture()
        _ = try await fixture.session.connect(method: .localVPN, backend: .coreDevice)
        let setup = try fixture.session.acquire(.setup)
        let operation = try fixture.session.beginSetup(owner: setup.owner)
        let unavailable = DeviceStatus.unavailable(reason: "fresh status unavailable")
        XCTAssertTrue(fixture.session.completeSetup(operation, status: unavailable))
        XCTAssertEqual(fixture.session.state, .connected(route: .localVPN, backend: .coreDevice, status: unavailable))
        XCTAssertEqual(fixture.route.disconnects, 0)
        setup.release()
    }

    func testSetupCanHideProgressWhileRetainingItsBusyClaimAndKnownReadyConnection() async throws {
        let fixture = Fixture()
        let ready = try await fixture.session.connect(method: .localVPN, backend: .coreDevice)
        let setup = try fixture.session.acquire(.setup)
        let operation = try fixture.session.beginSetup(owner: setup.owner, showsProgress: false)
        XCTAssertTrue(fixture.session.isTransitioning); XCTAssertTrue(fixture.session.isBusy)
        XCTAssertFalse(fixture.session.showsConnectionProgress)
        XCTAssertTrue(fixture.session.completeSetup(operation))
        XCTAssertEqual(fixture.session.state, .connected(route: .localVPN, backend: .coreDevice, status: ready))
        setup.release()
    }

    func testSetupCannotEstablishAConnectionOrPromoteUnavailableAuthorityFromCachedReadyStatus() throws {
        for previouslyConnected in [false, true] {
            let fixture = Fixture()
            let unavailable = DeviceStatus.unavailable(reason: "not authoritative")
            fixture.session.updateStatus(unavailable, transportConnected: previouslyConnected)
            let setup = try fixture.session.acquire(.setup)
            let operation = try fixture.session.beginSetup(owner: setup.owner)
            XCTAssertTrue(fixture.session.completeSetup(operation, status: fixture.route.readyStatus, transportConnected: true))
            XCTAssertEqual(fixture.session.status, unavailable)
            XCTAssertEqual(fixture.session.activeMethod, previouslyConnected ? .localVPN : nil)
            setup.release()
        }
    }

    func testExplicitSetupDisconnectCannotPublishAStaleReadyStatus() async throws {
        let fixture = Fixture()
        _ = try await fixture.session.connect(method: .localVPN, backend: .coreDevice)
        let setup = try fixture.session.acquire(.setup)
        let operation = try fixture.session.beginSetup(owner: setup.owner)
        XCTAssertTrue(fixture.session.completeSetup(operation, status: fixture.route.readyStatus, transportConnected: false))
        XCTAssertNil(fixture.session.activeMethod); XCTAssertNil(fixture.session.activeBackend)
        if case .ready = fixture.session.status { XCTFail("A disconnected setup cannot retain a stale ready cache.") }
        setup.release()
    }

    func testExternalLossInvalidatesSetupCompletionAndItsCapturedStatus() async throws {
        let fixture = Fixture()
        _ = try await fixture.session.connect(method: .localVPN, backend: .coreDevice)
        let setup = try fixture.session.acquire(.setup)
        let operation = try fixture.session.beginSetup(owner: setup.owner)
        fixture.session.handle(.transportLost)
        XCTAssertTrue(fixture.session.isTransitioning)
        XCTAssertFalse(fixture.session.completeSetup(operation, status: fixture.route.readyStatus))
        XCTAssertFalse(fixture.session.isTransitioning)
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertNil(fixture.session.activeMethod)
        setup.release()
    }

    func testReleaseCanCloseASetupWithoutWaitingForTheSetupTaskToFinish() async throws {
        let fixture = Fixture()
        let setup = try fixture.session.acquire(.setup)
        let operation = try fixture.session.beginSetup(owner: setup.owner)
        let released = try await fixture.session.releaseConnection(owner: setup.owner)
        XCTAssertTrue(released)
        XCTAssertTrue(fixture.session.isTransitioning, "The cancelled setup still owns its completion boundary.")
        XCTAssertFalse(fixture.session.completeSetup(operation, status: fixture.route.readyStatus))
        XCTAssertFalse(fixture.session.isTransitioning)
        XCTAssertEqual(fixture.route.disconnects, 1)
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        setup.release()
        let run = try fixture.session.acquire(.run(UUID())); run.release()
    }

    func testOwnedTransitionsRequireTheExactOwner() async throws {
        let fixture = Fixture(), id = UUID()
        let lease = try fixture.session.acquire(.dictation(id))
        XCTAssertThrowsError(try fixture.session.beginConnection(method: .localVPN, backend: .coreDevice))
        XCTAssertThrowsError(try fixture.session.beginRelease(owner: .dictation(UUID())))
        _ = try await fixture.session.connect(method: .localVPN, backend: .coreDevice, owner: lease.owner)
        _ = try await fixture.session.releaseConnection(owner: lease.owner)
        XCTAssertEqual(fixture.session.owner, .dictation(id))
        lease.release(); XCTAssertNil(fixture.session.owner)
    }

    func testStaleLeaseCannotReleaseANewerLeaseWithTheSameOwnerValue() throws {
        let fixture = Fixture()
        let previous = try fixture.session.acquire(.repair)
        let stale = DeviceLease(session: fixture.session, id: previous.id, owner: previous.owner, client: previous.client)
        previous.release()
        let current = try fixture.session.acquire(.repair)
        stale.release()
        XCTAssertEqual(fixture.session.owner, .repair)
        XCTAssertThrowsError(try fixture.session.acquire(.setup))
        current.release(); XCTAssertNil(fixture.session.owner)
    }

    func testLateConnectionCompletionCannotResurrectAnExternallyLostSession() throws {
        let fixture = Fixture()
        let operation = try fixture.session.beginConnection(method: .localVPN, backend: .coreDevice)
        let outcome = fixture.session.handle(.transportLost, expected: fixture.session.identity)
        XCTAssertFalse(outcome.isIgnored)
        XCTAssertTrue(fixture.session.isTransitioning, "The old operation still owns its cleanup boundary.")
        XCTAssertFalse(fixture.session.completeConnection(operation, status: fixture.route.readyStatus))
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertNil(fixture.session.activeMethod); XCTAssertNil(fixture.session.activeBackend)
        XCTAssertFalse(fixture.session.isTransitioning)
    }

    func testReusedOperationIDStillRejectsAnOlderCompletionAndIdentity() throws {
        let fixture = Fixture(), id = UUID()
        let first = try fixture.session.beginConnection(method: .localVPN, backend: .coreDevice, id: id)
        let oldIdentity = fixture.session.identity
        XCTAssertTrue(fixture.session.completeConnection(first, status: .unavailable(reason: "first"), connected: false))
        let second = try fixture.session.beginConnection(method: .localVPN, backend: .coreDevice, id: id)
        XCTAssertFalse(fixture.session.isCurrent(oldIdentity))
        XCTAssertFalse(fixture.session.completeConnection(first, status: fixture.route.readyStatus))
        XCTAssertTrue(fixture.session.isCurrent(second)); XCTAssertTrue(fixture.session.isTransitioning)
        XCTAssertTrue(fixture.session.completeConnection(second, status: fixture.route.readyStatus))
    }

    func testTransportLossClearsConnectionAndImmediatelyInvalidatesInput() async throws {
        let fixture = Fixture()
        _ = try await fixture.session.connect(method: .localVPN, backend: .coreDevice)
        let frame = try await fixture.session.client.captureScreenshot()
        let id = UUID(), lease = try fixture.session.acquire(.run(id))
        let outcome = fixture.session.handle(.transportLost, expected: fixture.session.identity)
        XCTAssertEqual(outcome.stopRunID, id); XCTAssertTrue(outcome.invalidatesPreview)
        XCTAssertFalse(outcome.preservesTransport)
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertNil(fixture.session.activeMethod); XCTAssertNil(fixture.session.activeBackend)
        do { try await lease.client.home(frameID: frame.frameID); XCTFail("The old grant must be revoked synchronously.") }
        catch { XCTAssertEqual(error as? DeviceControlError, .staleFrame) }
        XCTAssertTrue(fixture.route.actions.isEmpty)
        lease.release()
    }

    func testExternalOutcomeCapturesRunIDAndAStaleEventCannotStopANewerRun() throws {
        let fixture = Fixture()
        fixture.session.updateStatus(fixture.route.readyStatus)
        let oldID = UUID(), first = try fixture.session.acquire(.run(oldID))
        let before = fixture.session.identity
        var stopped: [UUID] = []
        fixture.session.onExternalStop = { id, _ in stopped.append(id) }
        let firstOutcome = fixture.session.handle(.geometryChanged)
        first.release()
        let newID = UUID(), second = try fixture.session.acquire(.run(newID))
        let stale = fixture.session.handle(.hardwareStopped, expected: before)
        XCTAssertTrue(stale.isIgnored); XCTAssertEqual(stopped, [oldID])
        XCTAssertEqual(firstOutcome.stopRunID, oldID)
        XCTAssertEqual(fixture.session.owner, .run(newID))
        let current = fixture.session.handle(.hardwareStopped, expected: fixture.session.identity)
        XCTAssertEqual(current.stopRunID, newID); XCTAssertEqual(stopped, [oldID, newID])
        second.release()
    }

    func testExternalIdentityExpiresWhenTheBorrowerChangesWithoutAConnectionTransition() throws {
        let fixture = Fixture()
        fixture.session.updateStatus(fixture.route.readyStatus)
        let first = try fixture.session.acquire(.run(UUID()))
        let previous = fixture.session.identity
        first.release()
        let newID = UUID(), second = try fixture.session.acquire(.run(newID))
        var stopped: [UUID] = []
        fixture.session.onExternalStop = { id, _ in stopped.append(id) }
        let outcome = fixture.session.handle(.transportLost, expected: previous)
        XCTAssertTrue(outcome.isIgnored); XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(fixture.session.owner, .run(newID))
        XCTAssertEqual(fixture.session.activeMethod, .localVPN)
        let current = fixture.session.handle(.transportLost, expected: fixture.session.identity)
        XCTAssertEqual(current.stopRunID, newID); XCTAssertEqual(stopped, [newID])
        second.release()
    }

    func testScreenAndGeometryChangesRetainTransportButRevokeReadiness() throws {
        for event in [DeviceSession.ExternalEvent.screenSharingStopped, .geometryChanged] {
            let fixture = Fixture()
            try fixture.session.configure(method: .bluetoothBoard, backend: .automatic, client: fixture.session.client)
            fixture.session.updateStatus(fixture.route.readyStatus)
            let outcome = fixture.session.handle(event, status: .unavailable(reason: "calibration required"))
            XCTAssertTrue(outcome.preservesTransport); XCTAssertTrue(outcome.invalidatesPreview)
            XCTAssertEqual(fixture.session.activeMethod, .bluetoothBoard)
            XCTAssertNil(fixture.session.activeBackend)
            XCTAssertEqual(fixture.session.state, .connected(route: .bluetoothBoard, backend: nil, status: .unavailable(reason: "calibration required")))
            XCTAssertEqual(fixture.route.disconnects, 0)
        }
    }

    func testBackgroundCancelsCapturedDictationWithoutDisconnectingOrStoppingADeviceRun() throws {
        let fixture = Fixture()
        fixture.session.updateStatus(fixture.route.readyStatus)
        let id = UUID(), dictation = try fixture.session.acquire(.dictation(id))
        let before = fixture.session.identity
        var cancelled: [UUID] = []
        fixture.session.onInvalidateDictation = { id, _ in cancelled.append(id) }
        let result = fixture.session.handle(.backgrounded)
        XCTAssertEqual(result.cancelDictationID, id); XCTAssertNil(result.stopRunID)
        XCTAssertEqual(cancelled, [id]); XCTAssertFalse(fixture.session.isCurrent(before))
        XCTAssertEqual(fixture.session.activeMethod, .localVPN); XCTAssertEqual(fixture.route.disconnects, 0)
        dictation.release()
        let runID = UUID(), run = try fixture.session.acquire(.run(runID))
        let current = fixture.session.identity
        let backgrounded = fixture.session.handle(.backgrounded)
        XCTAssertNil(backgrounded.stopRunID); XCTAssertNil(backgrounded.cancelDictationID)
        XCTAssertFalse(backgrounded.invalidatesPreview); XCTAssertTrue(fixture.session.isCurrent(current))
        run.release()
    }

    func testEveryOwnerBlocksRouteSwitching() async throws {
        for owner in [DeviceSession.Owner.run(UUID()), .dictation(UUID()), .repair, .setup] {
            let fixture = Fixture(), lease = try fixture.session.acquire(owner)
            do { try await fixture.session.switchRoute(to: .usbBoard); XCTFail("An owner must retain its selected client.") }
            catch { XCTAssertEqual(error as? DeviceControlError, .busy) }
            XCTAssertEqual(fixture.route.disconnects, 0); XCTAssertEqual(fixture.session.selectedMethod, .localVPN)
            lease.release()
        }
    }

    func testRouteSwitchReleasesOldClientBeforeInstallingNewClientAndNeverConnectsIt() async throws {
        let fixture = Fixture(), replacement = SessionRoute()
        fixture.route.suspendDisconnect = true
        let target = DeviceClient(actuator: replacement, networkSetup: replacement)
        let task = Task { try await fixture.session.switchRoute(to: .usbBoard, client: target) }
        try await waitUntil { fixture.route.pendingDisconnect != nil }
        XCTAssertEqual(fixture.session.state, .switching(from: .localVPN, to: .usbBoard))
        XCTAssertTrue(fixture.session.client.device === fixture.client.device)
        XCTAssertThrowsError(try fixture.session.acquire(.run(UUID())))
        fixture.route.resumeDisconnect(); try await task.value
        XCTAssertTrue(fixture.session.client.device === target.device)
        XCTAssertEqual(fixture.session.selectedMethod, .usbBoard)
        XCTAssertEqual(fixture.session.state, .idle(route: .usbBoard))
        XCTAssertNil(fixture.session.activeMethod); XCTAssertNil(fixture.session.activeBackend)
        XCTAssertTrue(replacement.connections.isEmpty)
    }

    func testUnconfirmedNetworkReleaseBlocksSelectionAndNewBorrowersUntilExplicitRepair() async throws {
        let fixture = Fixture()
        fixture.route.confirmation = .unconfirmed
        do { try await fixture.session.switchRoute(to: .usbBoard); XCTFail("Unconfirmed media must remain owned by the old route.") }
        catch { XCTAssertTrue(error is DeviceSession.Failure) }
        XCTAssertEqual(fixture.session.selectedMethod, .localVPN)
        XCTAssertNil(fixture.session.activeMethod); XCTAssertTrue(fixture.session.hasUnconfirmedRelease)
        XCTAssertFalse(fixture.session.isTransitioning)
        XCTAssertThrowsError(try fixture.session.acquire(.run(UUID())))
        XCTAssertThrowsError(try fixture.session.configure(method: .usbBoard, backend: .coreDevice))
        let repair = try fixture.session.acquire(.repair)
        fixture.route.confirmation = .confirmed
        _ = try await fixture.session.releaseConnection(owner: repair.owner)
        repair.release()
        XCTAssertFalse(fixture.session.hasUnconfirmedRelease)
        let next = try fixture.session.acquire(.run(UUID())); next.release()
    }

    func testHIDReleaseDoesNotClaimMediaConfirmationOrBlockRouteSelection() async throws {
        let fixture = Fixture()
        try fixture.session.configure(method: .bluetoothBoard, backend: .automatic, client: fixture.client, networkClient: fixture.client)
        fixture.route.confirmation = .unconfirmed
        let confirmed = try await fixture.session.releaseConnection()
        XCTAssertFalse(confirmed); XCTAssertFalse(fixture.session.hasUnconfirmedRelease)
        try await fixture.session.switchRoute(to: .localVPN)
        XCTAssertEqual(fixture.session.selectedMethod, .localVPN)
    }

    func testHIDOnlyInitialClientNeverBecomesARetainedNetworkRoute() throws {
        let route = SessionRoute()
        let session = DeviceSession(client: DeviceClient(actuator: route))
        try session.configure(method: .bluetoothBoard, backend: .automatic)
        XCTAssertNil(session.networkClient)
        XCTAssertThrowsError(try session.configure(method: .localVPN, backend: .xcTest)) { error in
            XCTAssertEqual(error as? DeviceControlError, .routeUnsupported(.localVPN))
        }
        XCTAssertEqual(session.selectedMethod, .bluetoothBoard)
        XCTAssertNil(session.networkClient)
    }

    func testSelectingSameEffectiveBackendPreservesPendingConnectionAndItsIdentity() async throws {
        let fixture = Fixture()
        let operation = try fixture.session.beginConnection(method: .localVPN, backend: .automatic)
        let identity = fixture.session.identity
        try await fixture.session.selectBackend(.coreDevice)
        XCTAssertEqual(fixture.session.backendPreference, .coreDevice)
        XCTAssertTrue(fixture.session.isCurrent(identity)); XCTAssertTrue(fixture.session.isCurrent(operation))
        XCTAssertEqual(fixture.route.disconnects, 0)
        XCTAssertTrue(fixture.session.completeConnection(operation, status: fixture.route.readyStatus))
        XCTAssertEqual(fixture.session.activeBackend, .coreDevice)
    }

    func testSelectingDifferentBackendReleasesAnIdleClientAndNeverConnectsAutomatically() async throws {
        let fixture = Fixture()
        try await fixture.session.selectBackend(.xcTest)
        XCTAssertEqual(fixture.route.disconnects, 1)
        XCTAssertEqual(fixture.session.backendPreference, .xcTest)
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertTrue(fixture.route.connections.isEmpty)
    }

    func testRouteSwitchReusesOnlyTheCurrentConfirmedRelease() async throws {
        let fixture = Fixture()
        _ = try await fixture.session.releaseConnection()
        let refreshed = await fixture.session.refreshStatus()
        XCTAssertTrue(refreshed)
        try await fixture.session.switchRoute(to: .usbBoard)
        XCTAssertEqual(fixture.route.disconnects, 1)
        XCTAssertEqual(fixture.session.selectedMethod, .usbBoard)
        XCTAssertTrue(fixture.route.connections.isEmpty)
    }

    func testBackendChangeDoesNotRepeatAConfirmedRelease() async throws {
        let fixture = Fixture()
        _ = try await fixture.session.releaseConnection()
        try await fixture.session.selectBackend(.xcTest)
        XCTAssertEqual(fixture.route.disconnects, 1)
        XCTAssertEqual(fixture.session.backendPreference, .xcTest)
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertTrue(fixture.route.connections.isEmpty)
    }

    func testChangedConfigurationEventOrBorrowerCannotReuseAnOldReleaseReceipt() async throws {
        for invalidation in 0..<3 {
            let fixture = Fixture()
            _ = try await fixture.session.releaseConnection()
            switch invalidation {
            case 0: try fixture.session.configure(method: .localVPN, backend: .automatic)
            case 1: fixture.session.handle(.geometryChanged)
            default:
                let lease = try fixture.session.acquire(.setup); lease.release()
            }
            try await fixture.session.switchRoute(to: .usbBoard)
            XCTAssertEqual(fixture.route.disconnects, 2)
        }
    }

    func testConnectingAgainRevokesThePreviousReleaseReceipt() async throws {
        let fixture = Fixture()
        _ = try await fixture.session.releaseConnection()
        _ = try await fixture.session.connect(method: .localVPN, backend: .coreDevice)
        try await fixture.session.switchRoute(to: .usbBoard)
        XCTAssertEqual(fixture.route.disconnects, 2)
    }

    func testDiagnosticConnectCannotPublishAnActiveNetworkConnection() async throws {
        let fixture = Fixture()
        fixture.route.connectProducesReady = false
        let status = try await fixture.session.connect(method: .localVPN, backend: .coreDevice)
        if case .ready = status { XCTFail("The fixture must produce diagnostic-only status.") }
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertNil(fixture.session.activeMethod); XCTAssertNil(fixture.session.activeBackend)
        XCTAssertFalse(fixture.session.isBusy)
    }

    func testDelayedStatusFromAnOldClientCannotReplaceNewRouteState() async throws {
        let fixture = Fixture(), replacement = SessionRoute()
        fixture.route.suspendStatus = true
        let identity = fixture.session.identity
        let reading = Task { await fixture.session.refreshStatus(expected: identity) }
        try await waitUntil { fixture.route.pendingStatus != nil }
        let target = DeviceClient(actuator: replacement, networkSetup: replacement)
        try fixture.session.configure(method: .usbBoard, backend: .xcTest, client: target)
        fixture.route.resumeStatus()
        let applied = await reading.value
        XCTAssertFalse(applied)
        XCTAssertTrue(fixture.session.client.device === target.device)
        XCTAssertEqual(fixture.session.state, .idle(route: .usbBoard)); XCTAssertNil(fixture.session.activeMethod)
    }

    func testReleaseCancelsAndDrainsPendingConnectionBeforeUnlocking() async throws {
        let fixture = Fixture()
        fixture.route.suspendConnect = true
        let connecting = Task { try await fixture.session.connect(method: .localVPN, backend: .coreDevice) }
        try await waitUntil { fixture.route.pendingConnect != nil }
        let releasing = Task { try await fixture.session.releaseConnection() }
        try await waitUntil { if case .releasing = fixture.session.state { true } else { false } }
        XCTAssertThrowsError(try fixture.session.acquire(.setup)); XCTAssertEqual(fixture.route.disconnects, 0)
        fixture.route.resumeConnect()
        do { _ = try await connecting.value; XCTFail("Cancelled connection cannot publish ready state.") } catch { }
        let released = try await releasing.value
        XCTAssertTrue(released); XCTAssertEqual(fixture.route.disconnects, 1)
        XCTAssertFalse(fixture.session.isTransitioning); XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
        XCTAssertNil(fixture.session.activeMethod); XCTAssertNil(fixture.session.activeBackend)
    }

    func testSetupCanCancelDrainAndSwitchAPendingConnectionWithoutReleasingItsClaim() async throws {
        let fixture = Fixture()
        fixture.route.suspendConnect = true
        let connecting = Task { try await fixture.session.connect(method: .localVPN, backend: .coreDevice) }
        try await waitUntil { fixture.route.pendingConnect != nil }
        let setup = try fixture.session.acquire(.setup, cancellingConnection: true)
        XCTAssertThrowsError(try fixture.session.acquire(.run(UUID())))
        let releasing = Task { try await fixture.session.releaseConnection(owner: setup.owner) }
        try await waitUntil { if case .releasing = fixture.session.state { true } else { false } }
        fixture.route.resumeConnect()
        do { _ = try await connecting.value; XCTFail("The superseded connection cannot publish readiness.") } catch { }
        let released = try await releasing.value
        XCTAssertTrue(released)
        try await fixture.session.switchRoute(to: .usbBoard, owner: setup.owner)
        XCTAssertEqual(fixture.route.disconnects, 1)
        XCTAssertEqual(fixture.session.owner, .setup)
        XCTAssertEqual(fixture.session.state, .idle(route: .usbBoard))
        setup.release()
        let run = try fixture.session.acquire(.run(UUID())); run.release()
    }

    func testExternalLossDuringSwitchCannotInstallTheRequestedRouteLater() async throws {
        let fixture = Fixture()
        fixture.route.suspendDisconnect = true
        let switching = Task { try await fixture.session.switchRoute(to: .usbBoard) }
        try await waitUntil { fixture.route.pendingDisconnect != nil }
        _ = fixture.session.handle(.transportLost)
        XCTAssertTrue(fixture.session.isTransitioning)
        fixture.route.resumeDisconnect()
        do { try await switching.value; XCTFail("An externally invalidated selection cannot commit.") } catch { }
        XCTAssertFalse(fixture.session.isTransitioning)
        XCTAssertEqual(fixture.session.selectedMethod, .localVPN)
        XCTAssertEqual(fixture.session.state, .idle(route: .localVPN))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard predicate() else { XCTFail("Device session fixture did not reach its transition boundary."); throw CancellationError() }
    }
    @MainActor private struct Fixture {
        let route = SessionRoute()
        let client: DeviceClient
        let session: DeviceSession
        init() {
            client = DeviceClient(actuator: route, networkSetup: route)
            session = DeviceSession(client: client, operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        }
    }
}

@MainActor private final class SessionRoute: DeviceActuator, NetworkRouteSetup {
    var ready = false, connectProducesReady = true, suspendConnect = false, suspendDisconnect = false, suspendStatus = false
    var pendingConnect: CheckedContinuation<Void, Never>?, pendingDisconnect: CheckedContinuation<Void, Never>?, pendingStatus: CheckedContinuation<Void, Never>?
    var confirmation: ReleaseConfirmation = .confirmed
    var connections: [DeviceConnectionMethod] = [], disconnects = 0, probes = 0
    var actions: [DeviceAction] = []
    let geometry = DeviceFrameGeometry(sessionID: UUID(), revision: "fixture", width: 10, height: 20)
    var readyStatus: DeviceStatus { .ready(capabilities: [.screenshot, .tap, .home]) }
    func cachedStatus() async -> DeviceStatus {
        if suspendStatus { await withCheckedContinuation { pendingStatus = $0 } }
        return ready ? readyStatus : .unavailable(reason: "fixture disconnected")
    }
    func probe() async -> DeviceStatus { probes += 1; return await cachedStatus() }
    func capture() async throws -> DeviceScreenshot { DeviceScreenshot(width: 10, height: 20, mimeType: "image/jpeg", data: Data([1]), geometry: geometry) }
    func frameState() async throws -> DeviceFrameState { DeviceFrameState(geometry: geometry, isLive: true) }
    func perform(_ action: DeviceAction, frame: FrameGrant) async throws -> SubmissionResult { actions.append(action); return .submitted }
    func releaseInput() async throws {}
    func disconnect() async -> ReleaseConfirmation {
        disconnects += 1
        if suspendDisconnect { await withCheckedContinuation { pendingDisconnect = $0 } }
        ready = false; return confirmation
    }
    func listApplications() async throws -> [DeviceApplication] { [] }
    func hasPairingIdentity() async throws -> Bool { true }
    func importPairingIdentity(_ data: Data) async throws {}
    func removePairingIdentity() async throws {}
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func beginPairing(configuration: LocalVPNConfiguration) async -> AsyncThrowingStream<DevicePairingEvent, Error> { await beginPairing() }
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws { try await connect(.localVPN) }
    func connectUSBBoard(backend: DeviceControlBackend) async throws { try await connect(.usbBoard) }
    private func connect(_ method: DeviceConnectionMethod) async throws {
        connections.append(method)
        if suspendConnect { await withCheckedContinuation { pendingConnect = $0 } }
        ready = connectProducesReady
    }
    func resumeConnect() { suspendConnect = false; pendingConnect?.resume(); pendingConnect = nil }
    func resumeDisconnect() { suspendDisconnect = false; pendingDisconnect?.resume(); pendingDisconnect = nil }
    func resumeStatus() { suspendStatus = false; pendingStatus?.resume(); pendingStatus = nil }
    #if DEBUG
    func probeLegacyDeveloperServices(configuration: LocalVPNConfiguration) async throws -> Data { Data() }
    #endif
}
