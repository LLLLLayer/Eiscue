import EiscueDeviceCore
import Foundation
import ImageIO
import OSLog
@preconcurrency import PhoneAgentNCM

@MainActor final class LocalDeviceController: NSObject, DeviceActuator, NetworkRouteSetup, @preconcurrency NetServiceDelegate {
    private let identityStore: any PairingIdentityStore
    private let dependencies: LocalDeviceConnectionDependencies
    private var services: (any LocalDeviceSession)?
    private var discovery: (any LocalVPNDiscovering)?
    private var boardDiscovery: (any USBBoardDiscovering)?
    private var pairing: RemotePairingSession?
    private var advertisement: NetService?
    private var loopbackAdvertisement: LoopbackPairingPublisher?
    private var loopbackAdvertisementID: UUID?
    private var pairingTask: Task<Void, Never>?
    private var pairingContinuation: AsyncThrowingStream<DevicePairingEvent, Error>.Continuation?
    private var epoch = UUID()
    private var busy = false
    private var ready = false
    private var failure = String(localized: "device.status.not-connected", defaultValue: "Device not connected", bundle: EiscueDeviceResources.bundle)
    private var capturedGeometry: DeviceFrameGeometry?
    private var mediaReleaseTask: Task<Bool, Never>?
    private var mediaReleaseID: UUID?
    private var releaseUnconfirmed = false
    private var mediaRequested = false
    private var serviceVPNConfiguration: VPNLoopbackConfiguration?
    private var pendingMediaCleanup: (service: any LocalDeviceSession, configuration: VPNLoopbackConfiguration)?
    #if DEBUG
    private(set) var connectionDiagnostic: [String: String] = [:]
    #endif

    nonisolated init(identityStore: any PairingIdentityStore, dependencies: LocalDeviceConnectionDependencies = .live) {
        self.identityStore = identityStore
        self.dependencies = dependencies
        super.init()
    }

    func cachedStatus() async -> DeviceStatus {
        guard dependencies.supportsPhysicalDevice else { return .unavailable(reason: DeviceControlError.unsupported.localizedDescription) }
        guard ready, let services else { return .unavailable(reason: failure) }
        let capabilities = Set(services.supportedControlActions.compactMap { DeviceCapability(rawValue: $0.rawValue) })
        return .ready(capabilities: capabilities)
    }

    func probe() async -> DeviceStatus {
        guard !busy, mediaRequested, let services else { return await cachedStatus() }
        busy = true; let token = epoch
        defer { if token == epoch { busy = false } }
        do {
            let geometry = try await services.currentVideoGeometry()
            try ensureCurrent(token)
            // XCTest has no coordinate space until its first screenshot. A nil
            // geometry revokes an old grant but does not mean transport loss.
            if geometry == nil { capturedGeometry = nil }
            ready = true; failure = ""
        } catch {
            if epoch == token { ready = false; capturedGeometry = nil; failure = Self.message(error) }
        }
        return await cachedStatus()
    }

    func hasPairingIdentity() async throws -> Bool {
        guard var data = try identityStore.load() else { return false }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        _ = try PairingIdentityCodec.decode(data, requireCommitted: false)
        return true
    }

    func importPairingIdentity(_ data: Data) async throws {
        guard !busy, mediaReleaseTask == nil else { throw DeviceControlError.busy }
        let record = try PairingIdentityCodec.decode(data)
        disconnectNow()
        var canonical = try PairingIdentityCodec.encode(record)
        defer { canonical.resetBytes(in: canonical.startIndex..<canonical.endIndex) }
        try identityStore.save(canonical)
    }

    func removePairingIdentity() async throws {
        disconnectNow()
        try identityStore.remove()
    }

    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        await beginPairing(localVPNConfiguration: nil)
    }

    func beginPairing(configuration: LocalVPNConfiguration) async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        await beginPairing(localVPNConfiguration: configuration)
    }

    private func beginPairing(localVPNConfiguration: LocalVPNConfiguration?) async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DevicePairingEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let vpn: VPNLoopbackConfiguration?
        do {
            guard dependencies.supportsPhysicalDevice else { throw DeviceControlError.unsupported }
            // Reject before starting the listener or reading an identity. The
            // responder protocol cannot make a missing iOS 26 Settings UI appear.
            try LocalPairingRequirements.validateSystemPairing(on: ProcessInfo.processInfo.operatingSystemVersion)
            vpn = try localVPNConfiguration.map { try VPNLoopbackConfiguration(localAddress: $0.localAddress, peerAddress: $0.peerAddress) }
            guard !busy, pairingTask == nil, mediaReleaseTask == nil else { throw DeviceControlError.busy }
            guard try identityStore.load() == nil else { throw DeviceControlError.pairingAlreadyExists }
        } catch { continuation.finish(throwing: error); return stream }
        disconnectNow()
        let token = epoch
        busy = true
        let session = RemotePairingSession()
        pairing = session
        pairingContinuation = continuation
        pairingTask = Task { @MainActor [weak self] in
            guard let self else { continuation.finish(throwing: CancellationError()); return }
            defer {
                session.close()
                if epoch == token {
                    advertisement?.stop(); advertisement = nil
                    loopbackAdvertisement?.stop(); loopbackAdvertisement = nil; loopbackAdvertisementID = nil
                    pairing = nil; pairingTask = nil; pairingContinuation = nil; busy = false
                }
            }
            do {
                try await session.pair(authorized: true, persist: { record in
                    guard self.epoch == token else { throw CancellationError() }
                    var previous = try self.identityStore.load()
                    defer { if let size = previous?.count { previous?.resetBytes(in: 0..<size) } }
                    try PairingIdentityCodec.validateTransition(from: previous, to: record)
                    var encoded = try PairingIdentityCodec.encode(record)
                    defer { encoded.resetBytes(in: encoded.startIndex..<encoded.endIndex) }
                    try self.identityStore.save(encoded)
                }, update: { update in
                    guard self.epoch == token else { throw CancellationError() }
                    switch update {
                    case .listening(let info):
                        if let vpn {
                            let publicationID = UUID()
                            self.loopbackAdvertisement?.stop()
                            self.loopbackAdvertisementID = publicationID
                            self.loopbackAdvertisement = try LoopbackPairingPublisher(advertisement: info, configuration: vpn) { [weak self] event in
                                Task { @MainActor in
                                    guard let self, self.epoch == token, self.loopbackAdvertisementID == publicationID else { return }
                                    switch event {
                                    case .published: self.pairingContinuation?.yield(.waitingForDevice)
                                    case .failed(let error):
                                        self.pairingContinuation?.finish(throwing: error)
                                        self.disconnectNow()
                                        self.failure = error.localizedDescription
                                    }
                                }
                            }
                            break
                        }
                        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: info.identifier, port: Int32(info.port))
                        service.delegate = self
                        guard service.setTXTRecord(NetService.data(fromTXTRecord: info.txt.mapValues { Data($0.utf8) })) else {
                            throw DeviceControlError.connection(String(localized: "device.pairing.publish-failed", defaultValue: "Could not make system pairing available.", bundle: EiscueDeviceResources.bundle))
                        }
                        self.advertisement = service
                        service.publish()
                    case .code(let pin): continuation.yield(.code(pin))
                    case .persisted(let committed): if committed { continuation.yield(.identitySaved) }
                    case .completed: continuation.yield(.completed)
                    }
                })
                continuation.finish()
            } catch {
                if epoch == token { failure = Self.message(error) }
                continuation.finish(throwing: Self.convert(error))
            }
        }
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.epoch == token, self.pairingTask != nil else { return }
                self.disconnectNow()
            }
        }
        return stream
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard advertisement === sender else { return }
        pairingContinuation?.yield(.waitingForDevice)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard advertisement === sender else { return }
        let error = DeviceControlError.connection(String(localized: "device.pairing.network-denied", defaultValue: "Could not make pairing available. Allow Local Network access for Eiscue.", bundle: EiscueDeviceResources.bundle))
        pairingContinuation?.finish(throwing: error)
        disconnectNow()
        failure = error.localizedDescription
    }

    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws {
        try await connectLocalVPN(configuration: configuration, backend: .automatic)
    }

    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws {
        guard dependencies.supportsPhysicalDevice else { throw DeviceControlError.unsupported }
        let vpn: VPNLoopbackConfiguration
        do { vpn = try VPNLoopbackConfiguration(localAddress: configuration.localAddress, peerAddress: configuration.peerAddress) }
        catch { throw Self.convert(error) }
        try await connect(method: .localVPN, vpn: vpn, backend: backend)
    }

    func connectUSBBoard() async throws {
        try await connectUSBBoard(backend: .automatic)
    }

    func connectUSBBoard(backend: DeviceControlBackend) async throws {
        try await connect(method: .usbBoard, vpn: nil, backend: backend)
    }

    private func connect(method: DeviceConnectionMethod, vpn: VPNLoopbackConfiguration?, backend: DeviceControlBackend) async throws {
        guard dependencies.supportsPhysicalDevice else { throw DeviceControlError.unsupported }
        let resolvedBackend = backend.resolved(on: dependencies.operatingSystemVersion)
        guard resolvedBackend.isAvailable(on: dependencies.operatingSystemVersion) else { throw DeviceControlError.backendUnavailable(resolvedBackend) }
        guard !busy, mediaReleaseTask == nil else { throw DeviceControlError.busy }
        #if DEBUG
        connectionDiagnostic = ["state": "preparing", "phase": "identity", "method": method.rawValue,
                                "backend": resolvedBackend.rawValue]
        #endif
        guard var data = try identityStore.load() else { throw DeviceControlError.noIdentity }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let record = try PairingIdentityCodec.decode(data)
        var identity = try record.identity()
        defer { identity.clearSeed() }
        let release = disconnectNow()
        let connectionEpoch = epoch
        if let release {
            let confirmed = await release.value
            try Task.checkCancellation()
            guard confirmed else { throw DeviceControlError.connection(String(localized: "device.media.previous-release-unconfirmed", defaultValue: "The previous screen connection may still be active. Check the system’s remote-control status before reconnecting.", bundle: EiscueDeviceResources.bundle)) }
        }
        guard !releaseUnconfirmed else {
            throw DeviceControlError.connection(String(localized: "device.media.previous-release-unconfirmed", defaultValue: "The previous screen connection may still be active. Check the system’s remote-control status before reconnecting.", bundle: EiscueDeviceResources.bundle))
        }
        try ensureCurrent(connectionEpoch)
        guard !busy, mediaReleaseTask == nil else { throw DeviceControlError.busy }
        let token = epoch
        busy = true
        failure = switch method {
        case .bluetoothBoard: throw DeviceControlError.routeUnsupported(.bluetoothBoard)
        case .localVPN: String(localized: "device.status.discovering", defaultValue: "Finding the local VPN connection", bundle: EiscueDeviceResources.bundle)
        case .usbBoard: String(localized: "device.status.discovering-board", defaultValue: "Connecting to the USB network board", bundle: EiscueDeviceResources.bundle)
        }
        let service = dependencies.makeSession(resolvedBackend)
        services = service
        serviceVPNConfiguration = method == .localVPN ? vpn : nil
        defer {
            if epoch == token {
                busy = false; discovery?.cancel(); discovery = nil
                boardDiscovery?.cancel(); boardDiscovery = nil
            }
        }
        do {
            try await withTaskCancellationHandler {
                let authorization = ExistingSessionAuthorization(verifyExistingIdentity: true, screen: true, screenVideoStream: true, input: true)
                switch method {
                case .bluetoothBoard: throw DeviceControlError.routeUnsupported(.bluetoothBoard)
                case .localVPN:
                    guard let vpn else { throw LocalVPNError.invalidConfiguration }
                    #if DEBUG
                    connectionDiagnostic["phase"] = "vpnInterfaceAndDiscovery"
                    #endif
                    let discovery = dependencies.makeVPNDiscovery()
                    self.discovery = discovery
                    let port = try await discovery.discoverPort(configuration: vpn)
                    try ensureCurrent(token)
                    #if DEBUG
                    connectionDiagnostic["phase"] = "transport"
                    #endif
                    try await service.connectLocalVPN(identity: identity, authorization: authorization,
                                                      pairingPort: port, configuration: vpn)
                case .usbBoard:
                    #if DEBUG
                    connectionDiagnostic["phase"] = "boardDiscovery"
                    #endif
                    let discovery = dependencies.makeBoardDiscovery()
                    boardDiscovery = discovery
                    let candidate = try await discovery.discoverRemotePairing()
                    try ensureCurrent(token)
                    #if DEBUG
                    connectionDiagnostic["phase"] = "transport"
                    #endif
                    try await service.connect(identity: identity, authorization: authorization, discovery: candidate)
                }
                try ensureCurrent(token)
                #if DEBUG
                connectionDiagnostic["phase"] = "developerReadiness"
                #endif
                try await service.checkDeveloperReadiness()
                try ensureCurrent(token)
                mediaRequested = true
                #if DEBUG
                connectionDiagnostic["phase"] = "mediaStart"
                #endif
                try await service.startTouchMedia()
                try ensureCurrent(token)
                ready = true; failure = ""
                #if DEBUG
                recordConnectionInterfaces(service)
                connectionDiagnostic["state"] = "ready"
                connectionDiagnostic["phase"] = "ready"
                #endif
            } onCancel: { [weak self] in
                Task { @MainActor in if let self, self.epoch == token { self.disconnectNow() } }
            }
        } catch {
            guard epoch == token else { throw CancellationError() }
            #if DEBUG
            recordConnectionInterfaces(service)
            connectionDiagnostic["state"] = "failed"
            connectionDiagnostic.merge(LocalDeviceConnectionDiagnostic.metadata(error)) { _, latest in latest }
            #endif
            let connectionError = Self.convert(error)
            let release = disconnectNow(), stoppedEpoch = epoch
            if let release { _ = await release.value }
            if epoch == stoppedEpoch, !releaseUnconfirmed { failure = Self.message(connectionError) }
            throw connectionError
        }
    }

    #if DEBUG
    private func recordConnectionInterfaces(_ service: any LocalDeviceSession) {
        for (key, value) in discovery?.interfaceDiagnostic ?? [:] { connectionDiagnostic["discovery." + key] = value }
        for (key, value) in service.connectionInterfaceDiagnostic { connectionDiagnostic["transport." + key] = value }
    }

    /// Check the iOS 26 developer route with the existing identity. This creates
    /// no media/input session and does not change production readiness state.
    func probeLegacyDeveloperServices(configuration: LocalVPNConfiguration) async throws -> Data {
        guard dependencies.supportsPhysicalDevice else { throw DeviceControlError.unsupported }
        guard !busy, !ready, pairingTask == nil, mediaReleaseTask == nil else { throw DeviceControlError.busy }
        let vpn = try VPNLoopbackConfiguration(localAddress: configuration.localAddress, peerAddress: configuration.peerAddress)
        guard var data = try identityStore.load() else { throw DeviceControlError.noIdentity }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let record = try PairingIdentityCodec.decode(data)
        var identity = try record.identity()
        defer { identity.clearSeed() }
        let token = epoch
        let discovery = LocalVPNDiscovery()
        let probe = NativeDeveloperServices()
        busy = true; self.discovery = discovery; services = probe
        defer {
            probe.close(); discovery.cancel()
            if token == epoch { busy = false; self.discovery = nil; services = nil }
        }
        return try await withTaskCancellationHandler {
            let port = try await discovery.discoverPort(configuration: vpn)
            try ensureCurrent(token)
            try await probe.connectLocalVPN(identity: identity,
                authorization: ExistingSessionAuthorization(verifyExistingIdentity: true, screen: true),
                pairingPort: port, configuration: vpn)
            try ensureCurrent(token)
            try await probe.checkDeveloperReadiness()
            try ensureCurrent(token)
            let report = try await probe.probeLegacyDeveloperServices()
            try ensureCurrent(token)
            return report
        } onCancel: {
            Task { @MainActor in discovery.cancel(); probe.close() }
        }
    }
    #endif

    func releaseInput() async throws {
        guard !busy else { throw DeviceControlError.busy }
        // Native actions finish their press/release sequence before returning.
        // Drop the task's coordinates without closing the user's connection.
        capturedGeometry = nil
    }

    func disconnect() async -> ReleaseConfirmation {
        if let mediaReleaseTask {
            // Revoke a connect that is awaiting this same release. Sharing the
            // cleanup task must not let that suspended connect publish Ready.
            epoch = UUID(); ready = false; busy = false; capturedGeometry = nil
            return await mediaReleaseTask.value ? .confirmed : .unconfirmed
        }
        if services == nil, releaseUnconfirmed, let pendingMediaCleanup {
            return await recoverMediaRelease(pendingMediaCleanup) ? .confirmed : .unconfirmed
        }
        if let release = disconnectNow() { return await release.value ? .confirmed : .unconfirmed }
        return releaseUnconfirmed ? .unconfirmed : .confirmed
    }

    /// A later explicit release can rebuild only the transport needed to stop
    /// our original media session. It cannot create a new screen/input session.
    private func recoverMediaRelease(_ pending: (service: any LocalDeviceSession, configuration: VPNLoopbackConfiguration)) async -> Bool {
        epoch = UUID(); ready = false; capturedGeometry = nil
        let releaseID = UUID()
        mediaReleaseID = releaseID
        let discovery = dependencies.makeVPNDiscovery()
        self.discovery = discovery
        let task = Task { @MainActor [weak self, identityStore] in
            let confirmed = await BoundedMediaRelease.run(timeout: .seconds(125), stop: {
                if pending.service.confirmRetainedMediaRelease() { return }
                guard var data = try identityStore.load() else { throw DeviceControlError.noIdentity }
                defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
                let record = try PairingIdentityCodec.decode(data)
                var identity = try record.identity()
                defer { identity.clearSeed() }
                let port = try await discovery.discoverPort(configuration: pending.configuration)
                try Task.checkCancellation()
                try await pending.service.releaseRetainedMediaLocalVPN(identity: identity, pairingPort: port,
                    configuration: pending.configuration)
            }, close: {
                discovery.cancel()
                pending.service.close()
            })
            guard let self, self.mediaReleaseID == releaseID else { return confirmed }
            self.discovery = nil
            self.mediaReleaseTask = nil; self.mediaReleaseID = nil
            self.releaseUnconfirmed = !confirmed
            if confirmed { self.pendingMediaCleanup = nil }
            self.publishReleaseResult(confirmed)
            return confirmed
        }
        mediaReleaseTask = task
        return await task.value
    }

    private func publishReleaseResult(_ confirmed: Bool) {
        failure = confirmed ? String(localized: "device.status.released", defaultValue: "Device and screen disconnected", bundle: EiscueDeviceResources.bundle) : String(localized: "device.status.release-unconfirmed", defaultValue: "Device control stopped, but the screen connection may still be active. Check the system’s remote-control status.", bundle: EiscueDeviceResources.bundle)
    }
    @discardableResult private func disconnectNow() -> Task<Bool, Never>? {
        epoch = UUID(); ready = false; busy = false; capturedGeometry = nil
        pairingTask?.cancel(); pairingTask = nil
        pairing?.close(); pairing = nil
        pairingContinuation?.finish(throwing: CancellationError()); pairingContinuation = nil
        advertisement?.stop(); advertisement = nil
        loopbackAdvertisement?.stop(); loopbackAdvertisement = nil; loopbackAdvertisementID = nil
        discovery?.cancel(); discovery = nil
        boardDiscovery?.cancel(); boardDiscovery = nil
        let previous = services; services = nil
        let previousVPN = serviceVPNConfiguration; serviceVPNConfiguration = nil
        let shouldReleaseMedia = mediaRequested; mediaRequested = false
        if let previous, shouldReleaseMedia {
            let releaseID = UUID()
            mediaReleaseID = releaseID
            failure = String(localized: "device.status.releasing", defaultValue: "Device control stopped. Closing the screen connection.", bundle: EiscueDeviceResources.bundle)
            let task = Task { @MainActor [weak self] in
                let confirmed = await BoundedMediaRelease.run(
                    timeout: previous.mediaReleaseTimeout,
                    stop: {
                        guard try await previous.stopTouchMediaWhenIdle() else {
                            throw DeviceControlError.connection(String(localized: "device.media.start-incomplete", defaultValue: "Screen connection did not finish starting. Its closure is unconfirmed; check the system’s remote-control status.", bundle: EiscueDeviceResources.bundle))
                        }
                    },
                    close: { previous.close() })
                guard let self, self.mediaReleaseID == releaseID else { return confirmed }
                self.mediaReleaseTask = nil; self.mediaReleaseID = nil
                self.releaseUnconfirmed = !confirmed
                if !confirmed, previous.hasRetainedMediaCleanup, let previousVPN {
                    self.pendingMediaCleanup = (previous, previousVPN)
                }
                self.publishReleaseResult(confirmed)
                return confirmed
            }
            mediaReleaseTask = task
        } else {
            previous?.close()
            if mediaReleaseTask == nil, !releaseUnconfirmed { failure = String(localized: "device.status.disconnected", defaultValue: "Device disconnected", bundle: EiscueDeviceResources.bundle) }
        }
        return mediaReleaseTask
    }

    func capture() async throws -> DeviceScreenshot {
        let token = epoch
        return try await operation { service in
            let snapshot = try await service.captureVideoJPEGWithGeometry()
            let data = snapshot.data
            try self.ensureCurrent(token)
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 1, height > 1, width <= 16384, height <= 16384 else {
                throw DeviceControlError.connection(String(localized: "device.media.invalid-image", defaultValue: "The screen image is invalid.", bundle: EiscueDeviceResources.bundle))
            }
            guard ["image/jpeg", "image/png"].contains(snapshot.mimeType) else {
                throw DeviceControlError.connection(String(localized: "device.media.invalid-image", defaultValue: "The screen image is invalid.", bundle: EiscueDeviceResources.bundle))
            }
            let geometry = DeviceFrameGeometry(sessionID: token, revision: snapshot.geometry.id.uuidString, width: width, height: height)
            let frame = DeviceScreenshot(width: width, height: height, mimeType: snapshot.mimeType, data: data, geometry: geometry)
            self.capturedGeometry = geometry
            return frame
        }
    }

    func frameState() async throws -> DeviceFrameState {
        guard ready, let services else { throw DeviceControlError.notConnected }
        guard let capturedGeometry else { throw DeviceControlError.staleFrame }
        let token = epoch
        let current: NativeVideoGeometry?
        do { current = try await services.currentVideoGeometry(); try ensureCurrent(token) }
        catch { throw Self.convert(error) }
        guard let current else {
            #if DEBUG
            print("NCM capture geometry available=0")
            #endif
            self.capturedGeometry = nil; throw DeviceControlError.staleFrame
        }
        #if DEBUG
        if current.id.uuidString != capturedGeometry.revision { print("NCM capture geometry available=1 matches=0") }
        #endif
        let geometry = DeviceFrameGeometry(sessionID: token, revision: current.id.uuidString,
                                          width: capturedGeometry.width, height: capturedGeometry.height)
        return DeviceFrameState(geometry: geometry, isLive: true)
    }

    func perform(_ action: DeviceAction, frame: FrameGrant) async throws -> SubmissionResult {
        let service: any LocalDeviceSession
        do {
            try Task.checkCancellation()
            guard ready, let current = services else { throw DeviceControlError.notConnected }
            guard !busy else { throw DeviceControlError.busy }
            guard current.supportedControlActions.contains(where: { $0.rawValue == action.capability.rawValue }) else {
                throw DeviceControlError.capabilityUnavailable(action.capability)
            }
            let state = try await frameState()
            guard state.geometry == frame.geometry else { throw DeviceControlError.staleFrame }
            service = current
        } catch { return .notSubmitted((Self.convert(error) as? DeviceControlError) ?? .connectionLost) }
        busy = true; let token = epoch
        defer { if token == epoch { busy = false } }
        // GuardedDevice owns validation and single-use authority. Conversion is
        // transport-specific; it uses exactly the geometry attached to the grant.
        func point(_ point: DevicePoint) -> (UInt16, UInt16) {
            (UInt16((point.x / Double(frame.geometry.width) * 65535).rounded()),
             UInt16((point.y / Double(frame.geometry.height) * 65535).rounded()))
        }
        do {
            try await withTaskCancellationHandler {
                switch action {
                case .tap(let value):
                    let p = point(value); _ = try await service.tapDelivery(x: p.0, y: p.1)
                case .swipe(let from, let to, let duration):
                    let a = point(from), b = point(to), value = duration.components
                    let milliseconds = UInt16(value.seconds * 1000 + value.attoseconds / 1_000_000_000_000_000)
                    _ = try await service.dragDelivery(fromX: a.0, fromY: a.1, toX: b.0, toY: b.1, durationMS: milliseconds)
                case .typeText(let value): try await service.typeText(value)
                case .launch(let bundleID): try await service.launchApplication(bundleID: bundleID, arguments: [])
                case .home: try await service.home()
                case .pressKey: return
                }
                try ensureCurrent(token)
            } onCancel: { [weak self] in
                Task { @MainActor in if let self, self.epoch == token { self.disconnectNow() } }
            }
            return .submitted
        } catch NativeBackendError.coordinateSpaceChanged {
            capturedGeometry = nil; return .notSubmitted(.staleFrame)
        } catch NativeBackendError.unsupportedControlAction {
            return .notSubmitted(.capabilityUnavailable(action.capability))
        } catch NativeBackendError.busy {
            return .notSubmitted(.busy)
        } catch {
            // A cancellation or epoch change after dispatch cannot prove that
            // input did not reach the device, even after an acknowledged send.
            throw DeviceControlError.deliveryUnknown("")
        }
    }

    func listApplications() async throws -> [DeviceApplication] {
        try await operation { service in
            struct Row: Decodable { let name: String; let bundle_id: String }
            let data = try await service.installedApplications()
            guard data.count <= 4 * 1024 * 1024 else { throw DeviceControlError.connection(String(localized: "device.app-list.too-large", defaultValue: "The app list is too large.", bundle: EiscueDeviceResources.bundle)) }
            return try JSONDecoder().decode([Row].self, from: data)
                .map { DeviceApplication(bundleID: $0.bundle_id, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func ensureCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == epoch else { throw CancellationError() }
    }

    private func operation<T: Sendable>(_ body: (any LocalDeviceSession) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard ready, let services else { throw DeviceControlError.notConnected }
        guard !busy else { throw DeviceControlError.busy }
        busy = true
        let token = epoch
        defer { if epoch == token { busy = false } }
        do {
            return try await withTaskCancellationHandler {
                let result = try await body(services)
                try ensureCurrent(token)
                return result
            } onCancel: { [weak self] in
                Task { @MainActor in if let self, self.epoch == token { self.disconnectNow() } }
            }
        } catch {
            guard epoch == token else {
                if let error = error as? DeviceControlError, error.isDeliveryUnknown { throw error }
                throw CancellationError()
            }
            if case NativeBackendError.coordinateSpaceChanged = error {
                capturedGeometry = nil
                throw DeviceControlError.staleFrame
            }
            if case NativeBackendError.applicationQueryFailure(stage: 21, cause: let cause) = error,
               [UInt32(1), 2, 4].contains(cause) {
                // AppService queries use an independent read-only stream. The
                // native backend retains the parent session on these failures;
                // tearing it down here would also end working screen/control.
                capturedGeometry = nil
                throw Self.convert(error)
            }
            // Validation failures happen before native submission and preserve the connection.
            if let error = error as? DeviceControlError,
               [.staleFrame, .invalidCoordinates, .invalidDuration, .invalidText, .invalidBundleID, .unsupported, .busy].contains(error) { throw error }
            let release = disconnectNow(), stoppedEpoch = epoch
            if let release { _ = await release.value }
            if epoch == stoppedEpoch, !releaseUnconfirmed { failure = Self.message(error) }
            throw Self.convert(error)
        }
    }

    private static func convert(_ error: Error) -> Error {
        if let native = error as? NativeBackendError { NativeDeviceErrorPresentation.record(native) }
        if error is CancellationError || error is DeviceControlError { return error }
        if case NativeBackendError.coordinateSpaceChanged = error { return DeviceControlError.staleFrame }
        if case NativeBackendError.unsupportedControlAction = error { return DeviceControlError.serviceUnavailable(.input) }
        if case NativeBackendError.closed = error { return DeviceControlError.connectionLost }
        if case NativeBackendError.transport = error { return DeviceControlError.connectionLost }
        if case NativeBackendError.applicationQueryFailure(stage: 21, cause: let cause) = error, [UInt32(1), 2, 4].contains(cause) {
            return DeviceControlError.serviceUnavailable(.applicationList)
        }
        if case NativeBackendError.applicationQueryFailure = error { return DeviceControlError.connectionLost }
        if case NativeBackendError.screenshotFailure = error { return DeviceControlError.connectionLost }
        if let value = error as? NCMError {
            switch value { case .disconnected, .network: return DeviceControlError.connectionLost; default: break }
        }
        return DeviceControlError.connection(message(error))
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? DeviceControlError { return error.localizedDescription }
        if error is CancellationError { return String(localized: "device.operation.stopped", defaultValue: "The operation has stopped.", bundle: EiscueDeviceResources.bundle) }
        if let error = error as? LocalVPNError {
            switch error {
            case .inactive: return String(localized: "device.vpn.inactive", defaultValue: "The local VPN is off or its address does not match the configuration.", bundle: EiscueDeviceResources.bundle)
            case .ambiguousInterface: return String(localized: "device.vpn.ambiguous-interface", defaultValue: "Multiple VPN connections found. Keep only the local VPN selected for Eiscue.", bundle: EiscueDeviceResources.bundle)
            case .serviceNotFound: return String(localized: "device.vpn.service-not-found", defaultValue: "Pairing service not found. Check Developer Mode and the local VPN.", bundle: EiscueDeviceResources.bundle)
            case .ambiguousService: return String(localized: "device.vpn.ambiguous-service", defaultValue: "Multiple local pairing services found. Reconnect the local VPN.", bundle: EiscueDeviceResources.bundle)
            case .discoveryDenied: return String(localized: "device.vpn.discovery-denied", defaultValue: "Could not find local services. Allow Local Network access.", bundle: EiscueDeviceResources.bundle)
            case .invalidConfiguration: return String(localized: "device.vpn.invalid-configuration", defaultValue: "The local and peer addresses must be distinct, valid IPv4 addresses.", bundle: EiscueDeviceResources.bundle)
            }
        }
        if let error = error as? NativeBackendError { return NativeDeviceErrorPresentation.message(error) }
        if let error = error as? NCMError { return NCMDeviceErrorPresentation.message(error) }
        return String(localized: "device.operation.failed", defaultValue: "Device operation failed. Check Local Network permission, the connection method, and system pairing.", bundle: EiscueDeviceResources.bundle)
    }
}

enum NCMDeviceErrorPresentation {
    static func message(_ error: NCMError, bundle: Bundle = EiscueDeviceResources.bundle) -> String {
        switch error {
        case .interfaceUnavailable:
            return String(localized: "device.board.not-attached", defaultValue: "USB network board not found. Connect a configured board to this device.", bundle: bundle)
        case .interfaceAmbiguous:
            return String(localized: "device.board.multiple-boards", defaultValue: "Multiple USB network boards found. Connect only one board.", bundle: bundle)
        case .interfaceInvalid, .interfaceScopeUnsupported, .staleDiscovery:
            return String(localized: "device.board.connection-changed", defaultValue: "USB network board connection changed. Disconnect and reconnect the board.", bundle: bundle)
        case .pairingServiceUnavailable:
            return String(localized: "device.board.pairing-service-unavailable", defaultValue: "USB network board connected, but device pairing is unavailable. Keep the device unlocked, enable Developer Mode, then reconnect.", bundle: bundle)
        case .malformedReply, .unavailableBackend:
            return String(localized: "device.board.firmware-unavailable", defaultValue: "The board lacks the USB network service. Install Eiscue USB network firmware.", bundle: bundle)
        case .network, .disconnected:
            return String(localized: "device.board.interrupted", defaultValue: "USB network board disconnected. Check its cable and power.", bundle: bundle)
        case .timeout:
            return String(localized: "device.backend.timed-out", defaultValue: "The device did not respond in time. Keep it unlocked, then reconnect.", bundle: bundle)
        case .busy: return DeviceControlError.busy.localizedDescription
        }
    }
}

/// Translates native diagnostic categories into instructions suitable for the app.
/// Keep the native codes in local diagnostics, never in the main error message.
enum NativeDeviceErrorPresentation {
    private static let logger = Logger(subsystem: "org.eiscue.device", category: "connection")

    static func message(_ error: NativeBackendError, bundle: Bundle = EiscueDeviceResources.bundle) -> String {
        switch error {
        case .invalidIdentity: return DeviceControlError.invalidIdentity.localizedDescription
        case .protocolFailure(stage: _, cause: 2): return String(localized: "device.backend.timed-out", defaultValue: "The device did not respond in time. Keep it unlocked, then reconnect.", bundle: bundle)
        case .protocolFailure(stage: 7, cause: _): return String(localized: "device.backend.developer-mode", defaultValue: "Developer Mode is not ready. Turn it on in Settings and restart when asked.", bundle: bundle)
        case .protocolFailure(stage: 8, cause: _): return String(localized: "device.backend.ddi-not-ready", defaultValue: "The device is not ready for development. Connect it to Xcode on your computer and wait for device preparation to finish, then try again.", bundle: bundle)
        case .protocolFailure: return String(localized: "device.backend.protocol-failed", defaultValue: "Device connection failed. Keep the device unlocked, then reconnect.", bundle: bundle)
        // Media service lookup runs only after identity verification and developer preparation.
        // MissingService includes unusable ports or service flags, so do not claim iOS lacks it.
        case .touchPreparationFailure(stage: 38, cause: 8): return String(localized: "device.backend.automation-consent", defaultValue: "Device control needs system permission. Keep the device unlocked and allow automation when asked.", bundle: bundle)
        case .touchPreparationFailure(stage: 38, cause: 9): return String(localized: "device.backend.automation-geometry", defaultValue: "Could not confirm the screen size and orientation. Keep the device unlocked and steady, then reconnect.", bundle: bundle)
        case .touchPreparationFailure(stage: 38, cause: 14): return String(localized: "device.backend.touch-timed-out", defaultValue: "Device control setup timed out. Keep the device unlocked, then reconnect.", bundle: bundle)
        case .touchPreparationFailure(stage: 38, cause: _): return String(localized: "device.backend.touch-not-ready", defaultValue: "Device control could not start. Chat is still available.", bundle: bundle)
        case .touchPreparationFailure(stage: 10, cause: 4): return String(localized: "device.backend.screen-service-unavailable", defaultValue: "Pairing succeeded, but screen access is unavailable on this connection. Device control is unavailable; chat still works.", bundle: bundle)
        case .touchPreparationFailure(stage: 11, cause: 4): return String(localized: "device.backend.touch-service-unavailable", defaultValue: "Pairing succeeded, but touch input is unavailable on this connection. Device control is unavailable; chat still works.", bundle: bundle)
        case .touchPreparationFailure(stage: _, cause: 2): return String(localized: "device.backend.touch-timed-out", defaultValue: "Device control setup timed out. Keep the device unlocked, then reconnect.", bundle: bundle)
        case .touchPreparationFailure: return String(localized: "device.backend.touch-not-ready", defaultValue: "Device control could not start. Chat is still available.", bundle: bundle)
        case .coordinateSpaceChanged: return DeviceControlError.staleFrame.localizedDescription
        case .unsupportedControlAction: return DeviceControlError.serviceUnavailable(.input).localizedDescription
        case .automationDeliveryUnknown: return String(localized: "device.backend.automation-delivery-unknown", defaultValue: "The device did not confirm this action; it will not be repeated. Check the screen before reconnecting.", bundle: bundle)
        case .automationAuthorizationTimedOut: return String(localized: "device.backend.automation-authorization-timed-out", defaultValue: "System authorization timed out. Keep the device unlocked and reconnect. Enter your passcode only on the system’s Enable UI Automation screen if asked.", bundle: bundle)
        case .screenshotFailure: return String(localized: "device.backend.screenshot-failed", defaultValue: "Could not read the screen. Keep the device unlocked, then reconnect.", bundle: bundle)
        case .applicationQueryFailure(stage: 21, cause: let cause) where [UInt32(1), 2, 4].contains(cause):
            return String(localized: "device.backend.app-list-unavailable", defaultValue: "App list unavailable. View the screen and use the visible controls.", bundle: bundle)
        case .applicationQueryFailure: return String(localized: "device.backend.app-list-failed", defaultValue: "Could not read the app list. View the screen and use the visible controls instead.", bundle: bundle)
        case .busy: return DeviceControlError.busy.localizedDescription
        case .closed: return String(localized: "device.backend.closed", defaultValue: "Device connection closed.", bundle: bundle)
        case .transport: return String(localized: "device.backend.transport-failed", defaultValue: "Device connection lost. Reconnect the device.", bundle: bundle)
        default: return String(localized: "device.backend.invalid-state", defaultValue: "Device connection could not be completed. Reconnect from the Device page.", bundle: bundle)
        }
    }

    static func record(_ error: NativeBackendError) {
        // Only allowlisted operation names and numeric categories: no peer data or credentials.
        let diagnostic: (operation: String, stage: UInt32, cause: UInt32)
        switch error {
        case .protocolFailure(let stage, let cause): diagnostic = ("connection", stage, cause)
        case .touchPreparationFailure(let stage, let cause): diagnostic = ("prepare-control", stage, cause)
        case .screenshotFailure(let stage, let cause): diagnostic = ("screenshot", stage, cause)
        case .applicationQueryFailure(let stage, let cause): diagnostic = ("app-list", stage, cause)
        case .automationDeliveryUnknown(let cause): diagnostic = ("automation-input", 38, cause)
        case .automationAuthorizationTimedOut: diagnostic = ("automation-authorization", 38, 14)
        case .transport(let code):
            logger.error("operation=transport code=\(code, privacy: .public)")
            return
        default: return
        }
        #if DEBUG
        print("NCM native failure operation=\(diagnostic.operation) stage=\(diagnostic.stage) cause=\(diagnostic.cause)")
        fflush(stdout)
        #endif
        logger.error("operation=\(diagnostic.operation, privacy: .public) stage=\(diagnostic.stage, privacy: .public) cause=\(diagnostic.cause, privacy: .public)")
    }
}

enum PairingIdentityCodec {
    static func validateTransition(from previousData: Data?, to record: RemotePairRecord) throws {
        guard let previousData else { return }
        let previous = try decode(previousData, requireCommitted: false)
        guard previous.controllerID == record.controllerID, previous.seed == record.seed,
              previous.peerID == record.peerID, previous.peerPublicKey == record.peerPublicKey,
              previous.alternateIRK == record.alternateIRK, previous.peerUDID == record.peerUDID,
              previous.peerModel == record.peerModel, !previous.committed || record.committed else {
            throw DeviceControlError.invalidIdentity
        }
    }
    static func decode(_ data: Data, requireCommitted: Bool = true) throws -> RemotePairRecord {
        guard !data.isEmpty, data.count <= 32 * 1024 else { throw DeviceControlError.invalidIdentity }
        do {
            let record: RemotePairRecord
            if let plist = try? PropertyListDecoder().decode(RemotePairRecord.self, from: data) { record = plist }
            else { record = try JSONDecoder().decode(RemotePairRecord.self, from: data) }
            guard !requireCommitted || record.committed else { throw DeviceControlError.invalidIdentity }
            var identity = try record.identity(); identity.clearSeed()
            return record
        } catch { throw DeviceControlError.invalidIdentity }
    }
    static func encode(_ record: RemotePairRecord) throws -> Data {
        var identity = try record.identity(); identity.clearSeed()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(record)
    }
}
