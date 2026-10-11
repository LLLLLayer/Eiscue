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
    private var pairingTask: Task<Void, Never>?
    private var pairingContinuation: AsyncThrowingStream<DevicePairingEvent, Error>.Continuation?
    private var epoch = UUID()
    private var busy = false
    private var ready = false
    private var failure = String(localized: "device.status.not-connected", defaultValue: "The device is not connected.", bundle: .module)
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
        return ready ? .ready(capabilities: Set(DeviceCapability.allCases)) : .unavailable(reason: failure)
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
        let (stream, continuation) = AsyncThrowingStream<DevicePairingEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(16))
        do {
            guard dependencies.supportsPhysicalDevice else { throw DeviceControlError.unsupported }
            // Reject before starting the listener or reading an identity. The
            // responder protocol cannot make a missing iOS 26 Settings UI appear.
            try LocalPairingRequirements.validateSystemPairing(on: ProcessInfo.processInfo.operatingSystemVersion)
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
                        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: info.identifier, port: Int32(info.port))
                        service.delegate = self
                        guard service.setTXTRecord(NetService.data(fromTXTRecord: info.txt.mapValues { Data($0.utf8) })) else {
                            throw DeviceControlError.connection(String(localized: "device.pairing.publish-failed", defaultValue: "The system pairing entry point could not be published.", bundle: .module))
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
        let error = DeviceControlError.connection(String(localized: "device.pairing.network-denied", defaultValue: "The system pairing entry point could not be published. Check local network permission.", bundle: .module))
        pairingContinuation?.finish(throwing: error)
        disconnectNow()
        failure = error.localizedDescription
    }

    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws {
        guard dependencies.supportsPhysicalDevice else { throw DeviceControlError.unsupported }
        let vpn: VPNLoopbackConfiguration
        do { vpn = try VPNLoopbackConfiguration(localAddress: configuration.localAddress, peerAddress: configuration.peerAddress) }
        catch { throw Self.convert(error) }
        try await connect(method: .localVPN, vpn: vpn)
    }

    func connectUSBBoard() async throws {
        try await connect(method: .usbBoard, vpn: nil)
    }

    private func connect(method: DeviceConnectionMethod, vpn: VPNLoopbackConfiguration?) async throws {
        guard dependencies.supportsPhysicalDevice else { throw DeviceControlError.unsupported }
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
            guard confirmed else { throw DeviceControlError.connection(String(localized: "device.media.previous-release-unconfirmed", defaultValue: "The previous screen session's release is unconfirmed. Check the system remote control status before connecting again.", bundle: .module)) }
        }
        try ensureCurrent(connectionEpoch)
        guard !busy, mediaReleaseTask == nil else { throw DeviceControlError.busy }
        let token = epoch
        busy = true
        failure = method == .localVPN
            ? String(localized: "device.status.discovering", defaultValue: "Discovering the local VPN connection.", bundle: .module)
            : String(localized: "device.status.discovering-board", defaultValue: "Connecting to the USB board.", bundle: .module)
        let service = dependencies.makeSession()
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
            let release = disconnectNow(), stoppedEpoch = epoch
            if let release { _ = await release.value }
            if epoch == stoppedEpoch, !releaseUnconfirmed { failure = Self.message(error) }
            throw Self.convert(error)
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

    func disconnect() async {
        if let release = disconnectNow() { _ = await release.value }
    }
    @discardableResult private func disconnectNow() -> Task<Bool, Never>? {
        epoch = UUID(); ready = false; busy = false; frames.invalidate()
        pairingTask?.cancel(); pairingTask = nil
        pairing?.close(); pairing = nil
        pairingContinuation?.finish(throwing: CancellationError()); pairingContinuation = nil
        advertisement?.stop(); advertisement = nil
        discovery?.cancel(); discovery = nil
        boardDiscovery?.cancel(); boardDiscovery = nil
        let previous = services; services = nil
        let shouldReleaseMedia = mediaRequested; mediaRequested = false
        if let previous, shouldReleaseMedia {
            let releaseID = UUID()
            mediaReleaseID = releaseID
            failure = String(localized: "device.status.releasing", defaultValue: "Local control has stopped. Releasing the remote screen session.", bundle: .module)
            let task = Task { @MainActor [weak self] in
                let confirmed = await BoundedMediaRelease.run(
                    stop: {
                        guard try await previous.stopTouchMediaWhenIdle() else {
                            throw DeviceControlError.connection(String(localized: "device.media.start-incomplete", defaultValue: "Screen startup did not complete. The remote release cannot be confirmed.", bundle: .module))
                        }
                    },
                    close: { previous.close() })
                guard let self, self.mediaReleaseID == releaseID else { return confirmed }
                self.mediaReleaseTask = nil; self.mediaReleaseID = nil
                self.releaseUnconfirmed = !confirmed
                self.failure = confirmed ? String(localized: "device.status.released", defaultValue: "The device is disconnected, and the remote screen session has been released.", bundle: .module) : String(localized: "device.status.release-unconfirmed", defaultValue: "Local control has stopped, but release of the remote screen session is unconfirmed. Check the system remote control status.", bundle: .module)
                return confirmed
            }
            mediaReleaseTask = task
        } else {
            previous?.close()
            if mediaReleaseTask == nil, !releaseUnconfirmed { failure = String(localized: "device.status.disconnected", defaultValue: "The device is disconnected.", bundle: .module) }
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
                throw DeviceControlError.connection(String(localized: "device.media.invalid-image", defaultValue: "The received screen image is invalid.", bundle: .module))
            }
            let frame = DeviceScreenshot(width: width, height: height, mimeType: "image/jpeg", data: data)
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
            // Validation failures happen before native submission and preserve the connection.
            if let error = error as? DeviceControlError,
               [.staleFrame, .invalidCoordinates, .invalidDuration, .invalidText, .invalidBundleID].contains(error) { throw error }
            let release = disconnectNow(), stoppedEpoch = epoch
            if let release { _ = await release.value }
            if epoch == stoppedEpoch, !releaseUnconfirmed { failure = Self.message(error) }
            throw Self.convert(error)
        }
    }

    private static func convert(_ error: Error) -> Error {
        if error is CancellationError || error is DeviceControlError { return error }
        if let native = error as? NativeBackendError { NativeDeviceErrorPresentation.record(native) }
        return DeviceControlError.connection(message(error))
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? DeviceControlError { return error.localizedDescription }
        if error is CancellationError { return String(localized: "device.operation.stopped", defaultValue: "The operation has stopped.", bundle: .module) }
        if let error = error as? LocalVPNError {
            switch error {
            case .inactive: return String(localized: "device.vpn.inactive", defaultValue: "The local loopback VPN is off, or its interface address does not match the configuration.", bundle: .module)
            case .ambiguousInterface: return String(localized: "device.vpn.ambiguous-interface", defaultValue: "Multiple VPN interfaces were found. Keep only the intended local loopback VPN active.", bundle: .module)
            case .serviceNotFound: return String(localized: "device.vpn.service-not-found", defaultValue: "The local pairing service was not found. Check Developer Mode and the VPN connection.", bundle: .module)
            case .ambiguousService: return String(localized: "device.vpn.ambiguous-service", defaultValue: "Multiple local pairing services were found. Reconnect the VPN and try again.", bundle: .module)
            case .discoveryDenied: return String(localized: "device.vpn.discovery-denied", defaultValue: "Local service discovery failed. Allow local network access.", bundle: .module)
            case .invalidConfiguration: return String(localized: "device.vpn.invalid-configuration", defaultValue: "The local and peer addresses must be distinct, valid IPv4 addresses.", bundle: .module)
            }
        }
        if let error = error as? NativeBackendError { return NativeDeviceErrorPresentation.message(error) }
        if let error = error as? NCMError { return NCMDeviceErrorPresentation.message(error) }
        return String(localized: "device.operation.failed", defaultValue: "The device operation failed. Check local network permission, the selected connection method, and system pairing authorization.", bundle: .module)
    }
}

enum NCMDeviceErrorPresentation {
    static func message(_ error: NCMError, bundle: Bundle = .module) -> String {
        switch error {
        case .interfaceUnavailable:
            return String(localized: "device.board.not-attached", defaultValue: "No USB board was found. Connect the configured board to this device and try again. You can keep chatting.", bundle: bundle)
        case .interfaceAmbiguous:
            return String(localized: "device.board.multiple-boards", defaultValue: "More than one USB board connection was found. Keep one board connected and try again.", bundle: bundle)
        case .interfaceInvalid, .interfaceScopeUnsupported, .staleDiscovery:
            return String(localized: "device.board.connection-changed", defaultValue: "The USB board connection changed. Reconnect the board and try again.", bundle: bundle)
        case .pairingServiceUnavailable:
            return String(localized: "device.board.pairing-service-unavailable", defaultValue: "The board is connected, but this device's pairing service was not found. Keep the device unlocked with Developer Mode on, then try again.", bundle: bundle)
        case .malformedReply, .unavailableBackend:
            return String(localized: "device.board.firmware-unavailable", defaultValue: "The board did not provide the required connection service. Install the Eiscue board firmware and try again.", bundle: bundle)
        case .network, .disconnected:
            return String(localized: "device.board.interrupted", defaultValue: "The USB board connection was interrupted. Check its cable and power, then try again.", bundle: bundle)
        case .timeout:
            return String(localized: "device.backend.timed-out", defaultValue: "The device did not respond in time. Keep it unlocked and try connecting again. You can keep chatting.", bundle: bundle)
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
        case .protocolFailure(stage: _, cause: 2): return String(localized: "device.backend.timed-out", defaultValue: "The device did not respond in time. Keep it unlocked and try connecting again. You can keep chatting.", bundle: bundle)
        case .protocolFailure(stage: 7, cause: _): return String(localized: "device.backend.developer-mode", defaultValue: "Developer Mode is not ready. Enable it in Settings and restart when the system asks.", bundle: bundle)
        case .protocolFailure(stage: 8, cause: _): return String(localized: "device.backend.ddi-not-ready", defaultValue: "The device is not ready for development. Connect it to Xcode on your computer and wait for device preparation to finish, then try again.", bundle: bundle)
        case .protocolFailure: return String(localized: "device.backend.protocol-failed", defaultValue: "The device connection could not be completed. Keep the device unlocked and try again. You can keep chatting.", bundle: bundle)
        // Media service lookup runs only after identity verification and developer preparation.
        // MissingService includes unusable ports or service flags, so do not claim iOS lacks it.
        case .touchPreparationFailure(stage: 10, cause: 4): return String(localized: "device.backend.screen-service-unavailable", defaultValue: "Pairing is complete, but the screen service needed for device control could not be found. You can keep chatting; device control is currently unavailable.", bundle: bundle)
        case .touchPreparationFailure(stage: 11, cause: 4): return String(localized: "device.backend.touch-service-unavailable", defaultValue: "Pairing is complete, but the touch service needed for device control could not be found. You can keep chatting; device control is currently unavailable.", bundle: bundle)
        case .touchPreparationFailure(stage: _, cause: 2): return String(localized: "device.backend.touch-timed-out", defaultValue: "Preparing device control timed out. Keep the device unlocked and try again. You can keep chatting.", bundle: bundle)
        case .touchPreparationFailure: return String(localized: "device.backend.touch-not-ready", defaultValue: "Device control could not be started. You can keep chatting; device control is currently unavailable.", bundle: bundle)
        case .screenshotFailure: return String(localized: "device.backend.screenshot-failed", defaultValue: "The device screen could not be read. Keep the device unlocked and try connecting again.", bundle: bundle)
        case .applicationQueryFailure: return String(localized: "device.backend.app-list-failed", defaultValue: "The list of installed apps could not be read. Try connecting again.", bundle: bundle)
        case .busy: return DeviceControlError.busy.localizedDescription
        case .closed: return String(localized: "device.backend.closed", defaultValue: "The device connection is closed.", bundle: bundle)
        case .transport: return String(localized: "device.backend.transport-failed", defaultValue: "The local connection was interrupted. Try connecting again. You can keep chatting.", bundle: bundle)
        default: return String(localized: "device.backend.invalid-state", defaultValue: "The device connection could not be completed. Try connecting again.", bundle: bundle)
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
        case .transport(let code):
            logger.error("operation=transport code=\(code, privacy: .public)")
            return
        default: return
        }
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
