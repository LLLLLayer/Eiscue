import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
@testable import EiscueDeviceKit
@testable import PhoneAgentNCM

@Suite @MainActor struct ConnectionMethodTests {
    @Test func publicMethodsSelectOnlyTheRequestedControllerTransport() async throws {
        let controller = MethodRecordingController()
        let client = DeviceClient(controller: controller)
        let configuration = LocalVPNConfiguration(localAddress: "10.8.1.1", peerAddress: "10.8.0.1")
        try await client.connect(method: .usbBoard, configuration: configuration)
        #expect(await controller.methods == [.usbBoard])
        #expect(await controller.configurations.isEmpty)
        try await client.connect(method: .localVPN, configuration: configuration)
        try await client.connectLocalVPN()
        try await client.connectUSBBoard()
        #expect(await controller.methods == [.usbBoard, .localVPN, .localVPN, .usbBoard])
        #expect(await controller.configurations == [configuration, .defaults])
        #expect(try JSONDecoder().decode(DeviceConnectionMethod.self, from: JSONEncoder().encode(DeviceConnectionMethod.usbBoard)) == .usbBoard)
        #expect(Set(DeviceConnectionMethod.allCases) == [.bluetoothBoard, .localVPN, .usbBoard])
    }

    @Test func existingCustomControllersKeepAnUnsupportedBoardDefault() async {
        let client = DeviceClient(controller: VPNOnlyController())
        await #expect(throws: DeviceControlError.unsupported) { try await client.connectUSBBoard() }
        await #expect(throws: DeviceControlError.unsupported) { try await client.connect(method: .usbBoard) }
        await #expect(throws: DeviceControlError.unsupported) { try await client.pressKey(.search, frameID: UUID()) }
    }

    @Test func existingCustomControllersDisconnectWithoutClaimingConfirmedRelease() async {
        let controller = MethodRecordingController()
        let client = DeviceClient(controller: controller)
        #expect(await client.disconnectAndConfirmRelease() == false)
        #expect(await controller.disconnects == 1)
    }

    @Test(arguments: [true, false])
    func publicClientForwardsConfirmedAndUnconfirmedMediaRelease(confirmed: Bool) async throws {
        let fixture = try ConnectionFixture(majorVersion: 27)
        let client = fixture.client()
        try await client.connectUSBBoard(backend: .coreDevice)
        if !confirmed { fixture.session.mediaFailure = DeviceControlError.connection("synthetic release failure") }
        #expect(await client.disconnectAndConfirmRelease() == confirmed)
        #expect(fixture.session.mediaStops == 1 && fixture.session.closed)
        #expect(try await client.hasPairingIdentity())
        guard case .unavailable = await client.status() else { Issue.record("Released control must be unavailable"); return }
        #expect(await client.disconnectAndConfirmRelease() == confirmed,
                "A later no-session release must preserve an earlier unconfirmed outcome.")
        #expect(fixture.session.mediaStops == 1)
    }

    @Test func noSessionConfirmsReleaseWithoutCreatingAConnection() async throws {
        let fixture = try ConnectionFixture(majorVersion: 27)
        #expect(await fixture.client().disconnectAndConfirmRelease())
        #expect(fixture.sessionBackends.isEmpty)
        #expect(fixture.session.mediaStops == 0 && fixture.session.mediaStarts == 0)
        #expect(fixture.vpnFactoryCalls == 0 && fixture.boardFactoryCalls == 0)
    }

    @Test func backendChoicesResolveWithoutChangingExplicitSelections() throws {
        #expect(Set(DeviceControlBackend.allCases) == [.automatic, .coreDevice, .xcTest])
        for backend in DeviceControlBackend.allCases {
            #expect(try JSONDecoder().decode(DeviceControlBackend.self, from: JSONEncoder().encode(backend)) == backend)
        }
        for major in [25, 26, 27, 28] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
            #expect(DeviceControlBackend.automatic.resolved(on: version) == (major >= 27 ? .coreDevice : .xcTest))
            #expect(DeviceControlBackend.coreDevice.resolved(on: version) == .coreDevice)
            #expect(DeviceControlBackend.xcTest.resolved(on: version) == .xcTest)
            #expect(DeviceControlBackend.automatic.isAvailable(on: version) == (major >= 26))
            #expect(DeviceControlBackend.coreDevice.isAvailable(on: version) == (major >= 27))
            #expect(DeviceControlBackend.xcTest.isAvailable(on: version) == (major >= 26))
        }
    }

    @Test(arguments: [DeviceControlBackend.coreDevice, .xcTest])
    func existingCustomControllersRejectExplicitBackendsWithoutConnecting(backend: DeviceControlBackend) async {
        let controller = MethodRecordingController()
        let client = DeviceClient(controller: controller)
        await #expect(throws: DeviceControlError.unsupported) { try await client.connectLocalVPN(backend: backend) }
        await #expect(throws: DeviceControlError.unsupported) { try await client.connectUSBBoard(backend: backend) }
        await #expect(throws: DeviceControlError.unsupported) { try await client.connect(method: .localVPN, backend: backend) }
        await #expect(throws: DeviceControlError.unsupported) { try await client.connect(method: .usbBoard, backend: backend) }
        #expect(await controller.methods.isEmpty)
    }

    @Test func publicConnectionMethodsForwardBackendChoicesToSupportingControllers() async throws {
        let controller = BackendRecordingController()
        let client = DeviceClient(controller: controller)
        let configuration = LocalVPNConfiguration(localAddress: "10.8.1.1", peerAddress: "10.8.0.1")
        try await client.connect(method: .localVPN, configuration: configuration, backend: .xcTest)
        try await client.connect(method: .usbBoard, backend: .coreDevice)
        try await client.connectLocalVPN(configuration: configuration, backend: .coreDevice)
        try await client.connectUSBBoard(backend: .xcTest)
        try await client.connectLocalVPN()
        try await client.connectUSBBoard()
        #expect(await controller.backends == [.xcTest, .coreDevice, .coreDevice, .xcTest, .automatic, .automatic])
        #expect(await controller.configurations == [configuration, configuration, .defaults])
    }

    @Test(arguments: [DeviceConnectionMethod.localVPN, .usbBoard], [26, 27, 28])
    func automaticBackendResolvesOnceWhenCreatingTheSession(method: DeviceConnectionMethod, major: Int) async throws {
        let fixture = try ConnectionFixture(majorVersion: major)
        let client = fixture.client()
        try await client.connect(method: method)
        #expect(fixture.sessionBackends == [major >= 27 ? .coreDevice : .xcTest])
        #expect(fixture.session.mediaStarts == 1)
        await client.disconnect()
    }

    @Test(arguments: [DeviceConnectionMethod.localVPN, .usbBoard])
    func explicitBackendReachesTheSessionAndRetainsTaskReleaseContracts(method: DeviceConnectionMethod) async throws {
        for (major, backend) in [(26, DeviceControlBackend.xcTest), (27, .xcTest), (27, .coreDevice)] {
            let fixture = try ConnectionFixture(majorVersion: major)
            let client = fixture.client()
            try await client.connect(method: method, backend: backend)
            #expect(fixture.sessionBackends == [backend])
            let frame = try await client.captureScreenshot()
            try await client.finishTask()
            #expect(!fixture.session.closed && fixture.session.mediaStops == 0)
            await #expect(throws: DeviceControlError.staleFrame) {
                try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: frame.frameID)
            }
            await client.disconnect()
            #expect(fixture.session.mediaStops == 1 && fixture.session.closed)
        }
    }

    @Test(arguments: [DeviceConnectionMethod.localVPN, .usbBoard])
    func unavailableBackendIsRejectedBeforeIdentityDiscoveryOrSessionCreation(method: DeviceConnectionMethod) async throws {
        for (major, backend) in [(26, DeviceControlBackend.coreDevice), (25, .xcTest), (25, .automatic)] {
            let fixture = try ConnectionFixture(majorVersion: major)
            let resolved = backend.resolved(on: fixture.operatingSystemVersion)
            await #expect(throws: DeviceControlError.backendUnavailable(resolved)) {
                try await fixture.client().connect(method: method, backend: backend)
            }
            #expect(fixture.store.loadCalls == 0)
            #expect(fixture.sessionBackends.isEmpty)
            #expect(fixture.vpnFactoryCalls == 0 && fixture.boardFactoryCalls == 0)
            #expect(fixture.session.vpnConnections == 0 && fixture.session.boardConnections == 0)
        }
    }

    @Test(arguments: [DeviceConnectionMethod.localVPN, .usbBoard], [DeviceControlBackend.coreDevice, .xcTest])
    func selectedBackendFailureNeverFallsBack(method: DeviceConnectionMethod, backend: DeviceControlBackend) async throws {
        let fixture = try ConnectionFixture(majorVersion: 27)
        fixture.session.mediaFailure = NativeBackendError.touchPreparationFailure(stage: 10, cause: 4)
        let client = fixture.client()
        await #expect(throws: (any Error).self) { try await client.connect(method: method, backend: backend) }
        #expect(fixture.sessionBackends == [backend])
        #expect(fixture.session.vpnConnections + fixture.session.boardConnections == 1)
        #expect(fixture.session.mediaStarts == 1 && fixture.session.closed)
        #expect(fixture.vpnFactoryCalls == (method == .localVPN ? 1 : 0))
        #expect(fixture.boardFactoryCalls == (method == .usbBoard ? 1 : 0))
        guard case .unavailable = await client.status() else { Issue.record("A failed backend cannot grant control readiness"); return }
    }

    @Test func liveSessionMappingKeepsBackendFixedForItsLifetime() throws {
        for (backend, native) in [(DeviceControlBackend.coreDevice, NativeControlBackend.coreDevice), (.xcTest, .xcTest)] {
            let session = try #require(LocalDeviceConnectionDependencies.live.makeSession(backend) as? NativeDeveloperServices)
            #expect(session.controlBackend == native)
            session.close()
            #expect(session.controlBackend == native)
            #expect(session.supportedControlActions.isEmpty)
        }
    }

    @Test func boardConnectionReusesIdentityAndNeverCreatesVPNDiscovery() async throws {
        let fixture = try ConnectionFixture()
        let client = fixture.client()
        try await client.connect(method: .usbBoard)
        #expect(fixture.board.calls == 1)
        #expect(fixture.vpn.calls == 0)
        #expect(fixture.vpnFactoryCalls == 0)
        #expect(fixture.session.boardConnections == 1)
        #expect(fixture.session.vpnConnections == 0)
        #expect(fixture.session.peerID == "SYNTHETIC-PEER")
        #expect(fixture.session.authorizedExistingIdentity)
        #expect(fixture.session.authorizedInput)
        #expect(fixture.session.developerChecks == 1)
        #expect(fixture.session.mediaStarts == 1)
        #expect(await client.status() == .ready(capabilities: [.screenshot, .tap, .swipe, .textInput, .launchApplication, .home, .listApplications]))
        #expect(fixture.board.cancelled)
        await client.disconnect()
        #expect(fixture.session.closed)
    }

    @Test func reportedCapabilitiesExcludeUnimplementedActionsAndPNGKeepsItsMimeType() async throws {
        let fixture = try ConnectionFixture()
        fixture.session.supportedControlActions = [.screenshot, .tap, .swipe, .launchApplication, .listApplications]
        let client = fixture.client()
        try await client.connectUSBBoard()
        #expect(await client.status() == .ready(capabilities: [.screenshot, .tap, .swipe, .launchApplication, .listApplications]))
        let screenshot = try await client.captureScreenshot()
        #expect(screenshot.mimeType == "image/png")
        await #expect(throws: DeviceControlError.unsupported) { try await client.home() }
        await #expect(throws: DeviceControlError.unsupported) { try await client.typeText("synthetic") }
        #expect(!fixture.session.closed)
        try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: screenshot.frameID)
        #expect(fixture.session.taps == 1)
        await client.disconnect()
    }

    @Test func screenChangeDuringCaptureInvalidatesOldFramesWithoutClosingTheConnection() async throws {
        let fixture = try ConnectionFixture()
        let client = fixture.client()
        try await client.connectUSBBoard()
        let old = try await client.captureScreenshot()
        fixture.session.captureFailure = NativeBackendError.coordinateSpaceChanged
        await #expect(throws: DeviceControlError.staleFrame) { try await client.captureScreenshot() }
        #expect(!fixture.session.closed)
        await #expect(throws: DeviceControlError.staleFrame) {
            try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: old.frameID)
        }
        #expect(fixture.session.taps == 0)
        fixture.session.captureFailure = nil
        let current = try await client.captureScreenshot()
        try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: current.frameID)
        #expect(fixture.session.taps == 1)
        await client.disconnect()
    }

    @Test func VPNConnectionNeverCreatesBoardDiscovery() async throws {
        let fixture = try ConnectionFixture()
        try await fixture.client().connectLocalVPN()
        #expect(fixture.vpn.calls == 1)
        #expect(fixture.boardFactoryCalls == 0)
        #expect(fixture.session.vpnConnections == 1)
        #expect(fixture.session.boardConnections == 0)
        await fixture.client().disconnect()
    }

    @Test(arguments: [DeviceConnectionMethod.localVPN, .usbBoard])
    func taskCompletionRetainsSessionAndRequiresNewObservationForTheNextTask(method: DeviceConnectionMethod) async throws {
        let fixture = try ConnectionFixture()
        let client = fixture.client()
        try await client.connect(method: method)
        let oldFrame = try await client.captureScreenshot()

        try await client.finishTask()

        #expect(!fixture.session.closed)
        #expect(fixture.session.mediaStops == 0)
        guard case .ready = await client.status() else { Issue.record("Finishing a task must keep its connection ready"); return }
        await #expect(throws: DeviceControlError.staleFrame) {
            try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: oldFrame.frameID)
        }
        #expect(fixture.session.taps == 0)
        let newFrame = try await client.captureScreenshot()
        try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: newFrame.frameID)
        try await client.finishTask()
        #expect(fixture.session.taps == 1)
        #expect(fixture.session.vpnConnections + fixture.session.boardConnections == 1)
        #expect(fixture.session.mediaStarts == 1)

        await client.disconnect()
        #expect(fixture.session.closed)
        #expect(fixture.session.mediaStops == 1)
        guard case .unavailable = await client.status() else { Issue.record("Explicit disconnect must still end the connection"); return }
    }

    @Test(arguments: [UInt32(1), 2, 4])
    func isolatedAppListFailurePreservesScreenSessionButRequiresFreshObservation(cause: UInt32) async throws {
        let fixture = try ConnectionFixture()
        let client = fixture.client()
        try await client.connectLocalVPN()
        let oldFrame = try await client.captureScreenshot()
        let queryFailure = NativeBackendError.applicationQueryFailure(stage: 21, cause: cause)
        fixture.session.appListFailure = queryFailure
        await #expect(throws: DeviceControlError.connection(NativeDeviceErrorPresentation.message(queryFailure))) {
            try await client.listApplications()
        }
        #expect(!fixture.session.closed)
        #expect(fixture.session.mediaStops == 0)
        guard case .ready = await client.status() else { Issue.record("An isolated app query must not revoke working screen control"); return }
        await #expect(throws: DeviceControlError.staleFrame) {
            try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: oldFrame.frameID)
        }
        let current = try await client.captureScreenshot()
        try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: current.frameID)
        #expect(fixture.session.taps == 1)
        #expect(fixture.session.vpnConnections == 1, "Continuing observation must not reconnect or replay input.")
        await client.disconnect()
    }

    @Test(arguments: [NativeBackendError.transport(code: 3), .applicationQueryFailure(stage: 12, cause: 5), .malformedEvent])
    func appListTransportLossStillClosesTheSession(error: NativeBackendError) async throws {
        let fixture = try ConnectionFixture()
        let client = fixture.client()
        try await client.connectLocalVPN()
        fixture.session.appListFailure = error
        await #expect(throws: (any Error).self) { try await client.listApplications() }
        #expect(fixture.session.closed)
        #expect(fixture.session.mediaStops == 1)
        guard case .unavailable = await client.status() else { Issue.record("Transport loss cannot retain readiness"); return }
        await #expect(throws: DeviceControlError.notConnected) { try await client.captureScreenshot() }
    }

    @Test func diagnosticCandidatesAndReadinessCannotClaimInputReady() async throws {
        let fixture = try ConnectionFixture()
        fixture.session.mediaFailure = NativeBackendError.touchPreparationFailure(stage: 10, cause: 4)
        let client = fixture.client()
        await #expect(throws: (any Error).self) { try await client.connectUSBBoard() }
        guard case .unavailable = await client.status() else {
            Issue.record("Diagnostic discovery and developer checks must not grant device control"); return
        }
        #expect(fixture.session.boardConnections == 1)
        #expect(fixture.session.developerChecks == 1)
        #expect(fixture.session.closed)
        await #expect(throws: DeviceControlError.notConnected) { try await client.captureScreenshot() }
    }

    @Test func missingBoardFailsWithoutTryingVPNOrOpeningNativeSession() async throws {
        let fixture = try ConnectionFixture()
        fixture.board.failure = NCMError.interfaceUnavailable
        let client = fixture.client()
        await #expect(throws: DeviceControlError.connection(NCMDeviceErrorPresentation.message(.interfaceUnavailable))) {
            try await client.connectUSBBoard()
        }
        #expect(fixture.vpnFactoryCalls == 0)
        #expect(fixture.session.boardConnections == 0)
        #expect(fixture.session.closed)
        guard case .unavailable(let reason) = await client.status() else { Issue.record("Missing board cannot be ready"); return }
        #expect(reason == NCMDeviceErrorPresentation.message(.interfaceUnavailable))
    }

    @Test func cancelWhileDiscoveringClosesSessionAndDoesNotFallBack() async throws {
        let fixture = try ConnectionFixture()
        fixture.board.suspend = true
        let client = fixture.client()
        let pending = Task { try await client.connectUSBBoard() }
        try await waitUntil { fixture.board.calls == 1 }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(fixture.board.cancelled)
        #expect(fixture.session.closed)
        #expect(fixture.session.boardConnections == 0)
        #expect(fixture.vpnFactoryCalls == 0)
        guard case .unavailable = await client.status() else { Issue.record("Cancelled connection cannot be ready"); return }
    }

    @Test func explicitDisconnectInvalidatesAnInFlightDiscovery() async throws {
        let fixture = try ConnectionFixture()
        fixture.board.suspend = true
        let client = fixture.client()
        let pending = Task { try await client.connectUSBBoard() }
        try await waitUntil { fixture.board.calls == 1 }
        await client.disconnect()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(fixture.board.cancelled && fixture.session.closed)
        #expect(fixture.session.boardConnections == 0)
    }

    @Test func changingTransportPermanentlyInvalidatesPreviouslyObservedGeometry() async throws {
        let fixture = try ConnectionFixture()
        let client = fixture.client()
        try await client.connectUSBBoard()
        let oldFrame = try await client.captureScreenshot()
        try await client.connectLocalVPN()
        await #expect(throws: DeviceControlError.staleFrame) {
            try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: oldFrame.frameID)
        }
        #expect(fixture.session.taps == 0)
        let currentFrame = try await client.captureScreenshot()
        try await client.tap(at: DevicePoint(x: 1, y: 1), frameID: currentFrame.frameID)
        #expect(fixture.session.taps == 1)
        await client.disconnect()
    }

    @Test func scopedDiscoveryRejectsAgeAndEveryInterfaceChange() throws {
        let now = ContinuousClock.now
        let row = boardRow()
        let candidate = try boardCandidate(row: row, observedAt: now)
        try candidate.validate(currentInterface: row, now: now.advanced(by: .seconds(1)))
        #expect(throws: NCMError.staleDiscovery) { try candidate.validate(currentInterface: row, now: now.advanced(by: .seconds(3))) }
        #expect(throws: NCMError.staleDiscovery) { try candidate.validate(currentInterface: row, now: now.advanced(by: .seconds(-1))) }
        #expect(throws: NCMError.interfaceInvalid) { try candidate.validate(currentInterface: boardRow(index: 8), now: now) }
        #expect(throws: NCMError.interfaceInvalid) { try candidate.validate(currentInterface: boardRow(name: "en-other"), now: now) }
        #expect(throws: NCMError.interfaceInvalid) { try candidate.validate(currentInterface: boardRow(address: "10.7.1.1"), now: now) }
    }

    @Test func ND1CannotClaimAuthenticationScreenOrInputCapabilities() throws {
        for key in ["authenticated", "screenCaptured", "inputExecuted"] {
            var values = boardReplyValues()
            values[key] = true
            #expect(throws: NCMError.malformedReply) { try DiagnosticReply.decode(line(values)) }
        }
        var values = boardReplyValues()
        values["generation"] = 0
        #expect(throws: NCMError.malformedReply) { try DiagnosticReply.decode(line(values)) }
        values = boardReplyValues()
        values["result"] = "diagnostic-only"
        let reply = try DiagnosticReply.decode(line(values))
        #expect(throws: NativeBackendError.invalidCandidate) { try NCMDiscoveredEndpoint(reply: reply, family: 6, interface: boardRow()) }
    }

    @Test func NCMSelectionRejectsVPNAndWiFiInsteadOfUsingDefaultRouting() throws {
        let board = boardRow()
        let corporateVPN = NCMInterfaceBinding.Row(name: "utun-synthetic", index: 9, address: "10.7.1.1", mask: "255.255.255.0",
                                                   flags: UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT), linkType: UInt8(IFT_OTHER))
        #expect(try NCMInterfaceBinding.select([corporateVPN, board]) == board)
        #expect(throws: NCMError.interfaceUnavailable) { try NCMInterfaceBinding.select([corporateVPN]) }
        let wrongAddressOnVPN = NCMInterfaceBinding.Row(name: "utun-synthetic", index: 9, address: "192.168.7.2", mask: "255.255.255.0",
                                                      flags: UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT), linkType: UInt8(IFT_OTHER))
        #expect(throws: NCMError.interfaceInvalid) { try NCMInterfaceBinding.select([wrongAddressOnVPN]) }
        #expect(throws: NCMError.interfaceInvalid) { try NCMInterfaceBinding.validateType(.wifi) }
        #expect(throws: NCMError.interfaceInvalid) { try NCMInterfaceBinding.validateType(.cellular) }
        #expect(throws: NCMError.interfaceAmbiguous) { try NCMInterfaceBinding.select([board, boardRow(index: 8)]) }
    }

    @Test func wrongOrAmbiguousPairingCandidatesAreRejected() throws {
        var values = boardReplyValues()
        values["endpoints"] = [["index": 2, "service": "lockdown", "family": 6, "port": 12345]]
        let lockdown = try DiagnosticReply.decode(line(values))
        #expect(throws: NCMError.pairingServiceUnavailable) { try NCMDiscoveredEndpoint(reply: lockdown, family: 6, interface: boardRow()) }
        values["endpoints"] = [
            ["index": 2, "service": "remotepairing", "family": 6, "port": 12345],
            ["index": 3, "service": "remotepairing", "family": 6, "port": 12346],
        ]
        let ambiguous = try DiagnosticReply.decode(line(values))
        #expect(throws: NCMError.pairingServiceUnavailable) { try NCMDiscoveredEndpoint(reply: ambiguous, family: 6, interface: boardRow()) }
    }

    @Test(arguments: ["en", "zh-Hans"])
    func boardErrorsExplainTheNextActionInBothLanguages(language: String) throws {
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        let bundle = try #require(Bundle(url: url.deletingLastPathComponent()))
        for error in [NCMError.interfaceUnavailable, .interfaceAmbiguous, .interfaceInvalid, .staleDiscovery,
                      .pairingServiceUnavailable, .malformedReply, .network] {
            let message = NCMDeviceErrorPresentation.message(error, bundle: bundle)
            // Ordinary words such as "network" are valid prose, not leaked error codes.
            #expect(message != error.rawValue && !message.contains("device.board."))
            #expect(!message.contains("ND1") && !message.contains("NR1"))
            #expect(language == "en" ? message.contains("board") : message.contains("开发板"))
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        throw TestFailure.didNotStart
    }
}

private enum TestFailure: Error { case didNotStart }

private actor MethodRecordingController: DeviceController {
    var methods: [DeviceConnectionMethod] = []
    var configurations: [LocalVPNConfiguration] = []
    var disconnects = 0
    func status() async -> DeviceStatus { .unavailable(reason: "synthetic") }
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws {
        methods.append(.localVPN); configurations.append(configuration)
    }
    func connectUSBBoard() async throws { methods.append(.usbBoard) }
    func disconnect() async { disconnects += 1 }
}
private actor VPNOnlyController: DeviceController {
    func status() async -> DeviceStatus { .unavailable(reason: "synthetic") }
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws {}
}
private actor BackendRecordingController: DeviceController {
    var backends: [DeviceControlBackend] = []
    var configurations: [LocalVPNConfiguration] = []
    func status() async -> DeviceStatus { .unavailable(reason: "synthetic") }
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws {
        backends.append(backend); configurations.append(configuration)
    }
    func connectUSBBoard(backend: DeviceControlBackend) async throws { backends.append(backend) }
}

@MainActor private final class ConnectionFixture {
    let board: TestBoardDiscovery
    let vpn = TestVPNDiscovery()
    let session: TestDeviceSession
    let store: TestConnectionIdentityStore
    let operatingSystemVersion: OperatingSystemVersion
    var sessionBackends: [DeviceControlBackend] = []
    var vpnFactoryCalls = 0
    var boardFactoryCalls = 0
    private var controller: LocalDeviceController?
    init(majorVersion: Int = 26) throws {
        operatingSystemVersion = OperatingSystemVersion(majorVersion: majorVersion, minorVersion: 0, patchVersion: 0)
        board = TestBoardDiscovery(candidate: try boardCandidate())
        session = try TestDeviceSession()
        store = TestConnectionIdentityStore(data: try JSONSerialization.data(withJSONObject: [
            "version": 1, "seed": Array(repeating: 66, count: 32), "controllerID": "SYNTHETIC-CONTROLLER",
            "peerID": "SYNTHETIC-PEER", "peerPublicKey": Array(repeating: 68, count: 32),
            "alternateIRK": Array(repeating: 51, count: 16), "peerUDID": "SYNTHETIC-UDID",
            "peerModel": "SYNTHETIC-MODEL", "committed": true,
        ]))
    }
    func client() -> DeviceClient {
        if let controller { return DeviceClient(controller: controller) }
        let dependencies = LocalDeviceConnectionDependencies(
            supportsPhysicalDevice: true,
            operatingSystemVersion: operatingSystemVersion,
            makeSession: { [self] backend in sessionBackends.append(backend); return session },
            makeVPNDiscovery: { [self] in vpnFactoryCalls += 1; return vpn },
            makeBoardDiscovery: { [self] in boardFactoryCalls += 1; return board }
        )
        let controller = LocalDeviceController(identityStore: store, dependencies: dependencies)
        self.controller = controller
        return DeviceClient(controller: controller)
    }
}

private final class TestConnectionIdentityStore: PairingIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var loads = 0
    var loadCalls: Int { lock.withLock { loads } }
    init(data: Data) { self.data = data }
    func load() throws -> Data? { lock.withLock { loads += 1; return data } }
    func save(_ data: Data) throws { lock.withLock { self.data = data } }
    func remove() throws { lock.withLock { data = nil } }
}

@MainActor private final class TestVPNDiscovery: LocalVPNDiscovering {
    var calls = 0
    var cancelled = false
    func discoverPort(configuration: VPNLoopbackConfiguration) async throws -> UInt16 { calls += 1; return 12345 }
    func cancel() { cancelled = true }
}

@MainActor private final class TestBoardDiscovery: USBBoardDiscovering {
    let candidate: NCMDiscoveredEndpoint
    var calls = 0
    var cancelled = false
    var failure: (any Error)?
    var suspend = false
    private var pending: CheckedContinuation<NCMDiscoveredEndpoint, any Error>?
    init(candidate: NCMDiscoveredEndpoint) { self.candidate = candidate }
    func discoverRemotePairing() async throws -> NCMDiscoveredEndpoint {
        calls += 1
        if let failure { throw failure }
        if suspend {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { pending = $0 }
            } onCancel: {
                Task { @MainActor [self] in cancel() }
            }
        }
        return candidate
    }
    func cancel() {
        cancelled = true
        pending?.resume(throwing: CancellationError()); pending = nil
    }
}

@MainActor private final class TestDeviceSession: LocalDeviceSession {
    var supportedControlActions = Set(NativeControlAction.allCases)
    var boardConnections = 0, vpnConnections = 0, developerChecks = 0, mediaStarts = 0, mediaStops = 0, taps = 0
    var closed = false, authorizedExistingIdentity = false, authorizedInput = false
    var peerID: String?
    var mediaFailure: (any Error)?
    var captureFailure: (any Error)?
    var appListFailure: (any Error)?
    private var geometry = NativeVideoGeometry(id: UUID(), epoch: 1, revision: 1)
    private let image: Data
    init() throws {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let cgImage = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        image = data as Data
    }
    func connectLocalVPN(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                         pairingPort: UInt16, configuration: VPNLoopbackConfiguration) async throws {
        vpnConnections += 1; record(identity, authorization)
    }
    func connect(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                 discovery: NCMDiscoveredEndpoint) async throws {
        try discovery.validate(currentInterface: boardRow())
        boardConnections += 1; record(identity, authorization)
    }
    private func record(_ identity: AuthorizedRemoteIdentity, _ authorization: ExistingSessionAuthorization) {
        closed = false; peerID = identity.peerID
        authorizedExistingIdentity = authorization.verifyExistingIdentity; authorizedInput = authorization.input
        geometry = NativeVideoGeometry(id: UUID(), epoch: 1, revision: 1)
    }
    func checkDeveloperReadiness() async throws { developerChecks += 1 }
    func startTouchMedia() async throws { mediaStarts += 1; if let mediaFailure { throw mediaFailure } }
    func stopTouchMediaWhenIdle() async throws -> Bool { mediaStops += 1; return mediaFailure == nil }
    func close() { closed = true }
    func captureVideoJPEGWithGeometry() async throws -> NativeVideoSnapshot {
        if let captureFailure { throw captureFailure }
        return NativeVideoSnapshot(data: image, geometry: geometry, mimeType: "image/png")
    }
    func currentVideoGeometry() async throws -> NativeVideoGeometry? { geometry }
    func tapDelivery(x: UInt16, y: UInt16) async throws -> InputDelivery { taps += 1; return .reportsWrittenVisualEffectUnverified }
    func dragDelivery(fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16) async throws -> InputDelivery { .reportsWrittenVisualEffectUnverified }
    func typeText(_ text: String) async throws {}
    func launchApplication(bundleID: String, arguments: [String]) async throws {}
    func home() async throws {}
    func installedApplications() async throws -> Data {
        if let appListFailure { throw appListFailure }
        return Data("[]".utf8)
    }
}

private func boardRow(index: UInt32 = 7, name: String = "en-synthetic", address: String = "192.168.7.2") -> NCMInterfaceBinding.Row {
    NCMInterfaceBinding.Row(name: name, index: index, address: address, mask: "255.255.255.0",
                           flags: UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST), linkType: UInt8(IFT_ETHER))
}
private func boardReplyValues() -> [String: Any] {
    ["protocol": "ND1", "layer": "discovery", "result": "candidates", "generation": 7, "authenticated": false,
     "screenCaptured": false, "inputExecuted": false,
     "endpoints": [["index": 2, "service": "remotepairing", "family": 6, "port": 12345]]]
}
private func line(_ values: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: values) + Data([10]) }
private func boardCandidate(row: NCMInterfaceBinding.Row = boardRow(), observedAt: ContinuousClock.Instant = .now) throws -> NCMDiscoveredEndpoint {
    try NCMDiscoveredEndpoint(reply: DiagnosticReply.decode(line(boardReplyValues())), family: 6,
                             interface: row, observedAt: observedAt)
}
