import Foundation
import ImageIO
import OSLog
@preconcurrency import PhoneAgentNCM

@MainActor final class LocalDeviceController: NSObject, DeviceController, @preconcurrency NetServiceDelegate {
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
    private var failure = String(localized: "device.status.not-connected", defaultValue: "Device not connected", bundle: .module)
    private var frames = FrameLedger()
    private var mediaReleaseTask: Task<Bool, Never>?
    private var mediaReleaseID: UUID?
    private var releaseUnconfirmed = false
    private var mediaRequested = false

    nonisolated init(identityStore: any PairingIdentityStore, dependencies: LocalDeviceConnectionDependencies = .live) {
        self.identityStore = identityStore
        self.dependencies = dependencies
        super.init()
    }

    func status() async -> DeviceStatus {
        guard dependencies.supportsPhysicalDevice else { return .unavailable(reason: DeviceControlError.unsupported.localizedDescription) }
        guard ready, let services else { return .unavailable(reason: failure) }
        let capabilities = Set(services.supportedControlActions.compactMap { DeviceCapability(rawValue: $0.rawValue) })
        return .ready(capabilities: capabilities)
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
                            throw DeviceControlError.connection(String(localized: "device.pairing.publish-failed", defaultValue: "Could not make system pairing available.", bundle: .module))
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
        let error = DeviceControlError.connection(String(localized: "device.pairing.network-denied", defaultValue: "Could not make pairing available. Allow Local Network access for Eiscue.", bundle: .module))
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
            guard confirmed else { throw DeviceControlError.connection(String(localized: "device.media.previous-release-unconfirmed", defaultValue: "The previous screen connection may still be active. Check the system’s remote-control status before reconnecting.", bundle: .module)) }
        }
        try ensureCurrent(connectionEpoch)
        guard !busy, mediaReleaseTask == nil else { throw DeviceControlError.busy }
        let token = epoch
        busy = true
        failure = switch method {
        case .bluetoothBoard: throw DeviceControlError.unsupported
        case .localVPN: String(localized: "device.status.discovering", defaultValue: "Finding the local VPN connection", bundle: .module)
        case .usbBoard: String(localized: "device.status.discovering-board", defaultValue: "Connecting to the USB network board", bundle: .module)
        }
        let service = dependencies.makeSession(resolvedBackend)
        services = service
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
                case .bluetoothBoard: throw DeviceControlError.unsupported
                case .localVPN:
                    guard let vpn else { throw LocalVPNError.invalidConfiguration }
                    let discovery = dependencies.makeVPNDiscovery()
                    self.discovery = discovery
                    let port = try await discovery.discoverPort(configuration: vpn)
                    try ensureCurrent(token)
                    try await service.connectLocalVPN(identity: identity, authorization: authorization,
                                                      pairingPort: port, configuration: vpn)
                case .usbBoard:
                    let discovery = dependencies.makeBoardDiscovery()
                    boardDiscovery = discovery
                    let candidate = try await discovery.discoverRemotePairing()
                    try ensureCurrent(token)
                    try await service.connect(identity: identity, authorization: authorization, discovery: candidate)
                }
                try ensureCurrent(token)
                try await service.checkDeveloperReadiness()
                try ensureCurrent(token)
                mediaRequested = true
                try await service.startTouchMedia()
                try ensureCurrent(token)
                ready = true; failure = ""
            } onCancel: { [weak self] in
                Task { @MainActor in if let self, self.epoch == token { self.disconnectNow() } }
            }
        } catch {
            guard epoch == token else { throw CancellationError() }
            let connectionError = Self.convert(error)
            let release = disconnectNow(), stoppedEpoch = epoch
            if let release { _ = await release.value }
            if epoch == stoppedEpoch, !releaseUnconfirmed { failure = Self.message(connectionError) }
            throw connectionError
        }
    }

    #if DEBUG
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

    func finishTask() async throws {
        guard !busy else { throw DeviceControlError.busy }
        // Native actions finish their press/release sequence before returning.
        // Drop the task's coordinates without closing the user's connection.
        frames.invalidate()
    }

    func disconnect() async {
        if let release = disconnectNow() { _ = await release.value }
    }
    func disconnectAndConfirmRelease() async -> Bool {
        if let release = disconnectNow() { return await release.value }
        return !releaseUnconfirmed
    }
    @discardableResult private func disconnectNow() -> Task<Bool, Never>? {
        epoch = UUID(); ready = false; busy = false; frames.invalidate()
        pairingTask?.cancel(); pairingTask = nil
        pairing?.close(); pairing = nil
        pairingContinuation?.finish(throwing: CancellationError()); pairingContinuation = nil
        advertisement?.stop(); advertisement = nil
        loopbackAdvertisement?.stop(); loopbackAdvertisement = nil; loopbackAdvertisementID = nil
        discovery?.cancel(); discovery = nil
        boardDiscovery?.cancel(); boardDiscovery = nil
        let previous = services; services = nil
        let shouldReleaseMedia = mediaRequested; mediaRequested = false
        if let previous, shouldReleaseMedia {
            let releaseID = UUID()
            mediaReleaseID = releaseID
            failure = String(localized: "device.status.releasing", defaultValue: "Device control stopped. Closing the screen connection.", bundle: .module)
            let task = Task { @MainActor [weak self] in
                let confirmed = await BoundedMediaRelease.run(
                    stop: {
                        guard try await previous.stopTouchMediaWhenIdle() else {
                            throw DeviceControlError.connection(String(localized: "device.media.start-incomplete", defaultValue: "Screen connection did not finish starting. Its closure is unconfirmed; check the system’s remote-control status.", bundle: .module))
                        }
                    },
                    close: { previous.close() })
                guard let self, self.mediaReleaseID == releaseID else { return confirmed }
                self.mediaReleaseTask = nil; self.mediaReleaseID = nil
                self.releaseUnconfirmed = !confirmed
                self.failure = confirmed ? String(localized: "device.status.released", defaultValue: "Device and screen disconnected", bundle: .module) : String(localized: "device.status.release-unconfirmed", defaultValue: "Device control stopped, but the screen connection may still be active. Check the system’s remote-control status.", bundle: .module)
                return confirmed
            }
            mediaReleaseTask = task
        } else {
            previous?.close()
            if mediaReleaseTask == nil, !releaseUnconfirmed { failure = String(localized: "device.status.disconnected", defaultValue: "Device disconnected", bundle: .module) }
        }
        return mediaReleaseTask
    }

    func captureScreenshot() async throws -> DeviceScreenshot {
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
                throw DeviceControlError.connection(String(localized: "device.media.invalid-image", defaultValue: "The screen image is invalid.", bundle: .module))
            }
            guard ["image/jpeg", "image/png"].contains(snapshot.mimeType) else {
                throw DeviceControlError.connection(String(localized: "device.media.invalid-image", defaultValue: "The screen image is invalid.", bundle: .module))
            }
            let frame = DeviceScreenshot(width: width, height: height, mimeType: snapshot.mimeType, data: data)
            self.frames.record(frame, geometryID: snapshot.geometry.id)
            return frame
        }
    }

    func tap(at point: DevicePoint, frameID: UUID) async throws {
        try await operation { service in
            let point = try await self.consumeFrame(service: service, id: frameID, points: [point])[0]
            try await self.deliver { _ = try await service.tapDelivery(x: point.0, y: point.1) }
        }
    }

    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws {
        guard duration >= .milliseconds(100), duration <= .seconds(2) else { throw DeviceControlError.invalidDuration }
        let value = duration.components
        let milliseconds = UInt16(value.seconds * 1000 + value.attoseconds / 1_000_000_000_000_000)
        try await operation { service in
            let points = try await self.consumeFrame(service: service, id: frameID, points: [from, to])
            try await self.deliver {
                _ = try await service.dragDelivery(fromX: points[0].0, fromY: points[0].1, toX: points[1].0, toY: points[1].1, durationMS: milliseconds)
            }
        }
    }

    func typeText(_ text: String) async throws { try await sendText(text, frameID: nil) }
    func typeText(_ text: String, frameID: UUID) async throws { try await sendText(text, frameID: frameID) }
    private func sendText(_ text: String, frameID: UUID?) async throws {
        try DeviceInputValidation.text(text)
        if ready, services?.supportedControlActions.contains(.textInput) == false { throw DeviceControlError.unsupported }
        try await operation { service in
            if let frameID { _ = try await self.consumeFrame(service: service, id: frameID, points: []) }
            else { self.frames.invalidate() }
            try await self.deliver { try await service.typeText(text) }
        }
    }

    func launchApplication(bundleID: String) async throws {
        try DeviceInputValidation.bundleID(bundleID)
        try await operation { service in
            self.frames.invalidate()
            try await self.deliver { try await service.launchApplication(bundleID: bundleID, arguments: []) }
        }
    }

    func home() async throws {
        if ready, services?.supportedControlActions.contains(.home) == false { throw DeviceControlError.unsupported }
        try await operation { service in
            self.frames.invalidate()
            try await self.deliver { try await service.home() }
        }
    }

    func listApplications() async throws -> [DeviceApplication] {
        try await operation { service in
            struct Row: Decodable { let name: String; let bundle_id: String }
            let data = try await service.installedApplications()
            guard data.count <= 4 * 1024 * 1024 else { throw DeviceControlError.connection(String(localized: "device.app-list.too-large", defaultValue: "The app list is too large.", bundle: .module)) }
            return try JSONDecoder().decode([Row].self, from: data)
                .map { DeviceApplication(bundleID: $0.bundle_id, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func ensureCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == epoch else { throw CancellationError() }
    }

    private func consumeFrame(service: any LocalDeviceSession, id: UUID, points: [DevicePoint]) async throws -> [(UInt16, UInt16)] {
        let token = epoch
        let geometry = try await service.currentVideoGeometry()
        try ensureCurrent(token)
        return try frames.consume(id: id, points: points, geometryID: geometry?.id)
    }

    private func deliver(_ body: () async throws -> Void) async throws {
        try Task.checkCancellation()
        do { try await body() }
        catch NativeBackendError.coordinateSpaceChanged { throw DeviceControlError.staleFrame }
        catch NativeBackendError.unsupportedControlAction { throw DeviceControlError.unsupported }
        catch NativeBackendError.busy { throw DeviceControlError.busy }
        catch { throw DeviceControlError.deliveryUnknown(Self.message(error)) }
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
                frames.invalidate()
                throw DeviceControlError.staleFrame
            }
            if case NativeBackendError.applicationQueryFailure(stage: 21, cause: let cause) = error,
               [UInt32(1), 2, 4].contains(cause) {
                // AppService queries use an independent read-only stream. The
                // native backend retains the parent session on these failures;
                // tearing it down here would also end working screen/control.
                frames.invalidate()
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
        if error is CancellationError || error is DeviceControlError { return error }
        if case NativeBackendError.coordinateSpaceChanged = error { return DeviceControlError.staleFrame }
        if case NativeBackendError.unsupportedControlAction = error { return DeviceControlError.unsupported }
        if let native = error as? NativeBackendError { NativeDeviceErrorPresentation.record(native) }
        return DeviceControlError.connection(message(error))
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? DeviceControlError { return error.localizedDescription }
        if error is CancellationError { return String(localized: "device.operation.stopped", defaultValue: "The operation has stopped.", bundle: .module) }
        if let error = error as? LocalVPNError {
            switch error {
            case .inactive: return String(localized: "device.vpn.inactive", defaultValue: "The local VPN is off or its address does not match the configuration.", bundle: .module)
            case .ambiguousInterface: return String(localized: "device.vpn.ambiguous-interface", defaultValue: "Multiple VPN connections found. Keep only the local VPN selected for Eiscue.", bundle: .module)
            case .serviceNotFound: return String(localized: "device.vpn.service-not-found", defaultValue: "Pairing service not found. Check Developer Mode and the local VPN.", bundle: .module)
            case .ambiguousService: return String(localized: "device.vpn.ambiguous-service", defaultValue: "Multiple local pairing services found. Reconnect the local VPN.", bundle: .module)
            case .discoveryDenied: return String(localized: "device.vpn.discovery-denied", defaultValue: "Could not find local services. Allow Local Network access.", bundle: .module)
            case .invalidConfiguration: return String(localized: "device.vpn.invalid-configuration", defaultValue: "The local and peer addresses must be distinct, valid IPv4 addresses.", bundle: .module)
            }
        }
        if let error = error as? NativeBackendError { return NativeDeviceErrorPresentation.message(error) }
        if let error = error as? NCMError { return NCMDeviceErrorPresentation.message(error) }
        return String(localized: "device.operation.failed", defaultValue: "Device operation failed. Check Local Network permission, the connection method, and system pairing.", bundle: .module)
    }
}

enum NCMDeviceErrorPresentation {
    static func message(_ error: NCMError, bundle: Bundle = .module) -> String {
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

    static func message(_ error: NativeBackendError, bundle: Bundle = .module) -> String {
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
        case .unsupportedControlAction: return DeviceControlError.unsupported.localizedDescription
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

enum DeviceInputValidation {
    static func text(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 8 * 1024, !text.utf8.contains(0),
              let payload = try? JSONSerialization.data(withJSONObject: ["text": text]), payload.count <= 16 * 1024 else {
            throw DeviceControlError.invalidText
        }
    }
    static func bundleID(_ bundleID: String) throws {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 256,
              bundleID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            throw DeviceControlError.invalidBundleID
        }
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
