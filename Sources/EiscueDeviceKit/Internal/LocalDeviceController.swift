import Foundation
import ImageIO
@preconcurrency import PhoneAgentNCM

@MainActor final class LocalDeviceController: NSObject, DeviceController, @preconcurrency NetServiceDelegate {
    private let identityStore: any PairingIdentityStore
    private var services: NativeDeveloperServices?
    private var discovery: LocalVPNDiscovery?
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

    nonisolated init(identityStore: any PairingIdentityStore) {
        self.identityStore = identityStore
        super.init()
    }

    private static var supported: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func status() async -> DeviceStatus {
        guard Self.supported else { return .unavailable(reason: DeviceControlError.unsupported.localizedDescription) }
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
            guard Self.supported else { throw DeviceControlError.unsupported }
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
        guard Self.supported else { throw DeviceControlError.unsupported }
        guard !busy, mediaReleaseTask == nil else { throw DeviceControlError.busy }
        let vpn: VPNLoopbackConfiguration
        do { vpn = try VPNLoopbackConfiguration(localAddress: configuration.localAddress, peerAddress: configuration.peerAddress) }
        catch { throw Self.convert(error) }
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
        busy = true; failure = String(localized: "device.status.discovering", defaultValue: "Discovering the local VPN connection.", bundle: .module)
        let discovery = LocalVPNDiscovery()
        let service = NativeDeveloperServices()
        self.discovery = discovery; services = service
        defer { if epoch == token { busy = false; self.discovery = nil } }
        do {
            try await withTaskCancellationHandler {
                let port = try await discovery.discoverPort(configuration: vpn)
                try ensureCurrent(token)
                try await service.connectLocalVPN(identity: identity,
                    authorization: ExistingSessionAuthorization(verifyExistingIdentity: true, screen: true, screenVideoStream: true, input: true),
                    pairingPort: port, configuration: vpn)
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

    private func consumeFrame(service: NativeDeveloperServices, id: UUID, points: [DevicePoint]) async throws -> [(UInt16, UInt16)] {
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

    private func operation<T: Sendable>(_ body: (NativeDeveloperServices) async throws -> T) async throws -> T {
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
        if let error = error as? NativeBackendError {
            switch error {
            case .invalidIdentity: return DeviceControlError.invalidIdentity.localizedDescription
            case .protocolFailure(stage: 7, cause: _): return String(localized: "device.backend.developer-mode", defaultValue: "Developer Mode is not ready. Enable it in Settings and restart when the system asks.", bundle: .module)
            case .protocolFailure(stage: 8, cause: _): return String(localized: "device.backend.ddi-not-ready", defaultValue: "The Developer Disk Image (DDI) is not ready. Connect the device to Xcode and complete development preparation before retrying. This app does not download or mount images.", bundle: .module)
            case .protocolFailure(let stage, let cause): return String(localized: "device.backend.protocol-failed", defaultValue: "The device protocol failed (stage \(String(describing: stage)), cause \(String(describing: cause))).", bundle: .module)
            case .touchPreparationFailure(let stage, let cause): return String(localized: "device.backend.touch-not-ready", defaultValue: "The screen or touch service is not ready (stage \(String(describing: stage)), cause \(String(describing: cause))).", bundle: .module)
            case .screenshotFailure(let stage, let cause): return String(localized: "device.backend.screenshot-failed", defaultValue: "A valid screen image could not be captured (stage \(String(describing: stage)), cause \(String(describing: cause))).", bundle: .module)
            case .applicationQueryFailure(let stage, let cause): return String(localized: "device.backend.app-list-failed", defaultValue: "The app list could not be read (stage \(String(describing: stage)), cause \(String(describing: cause))).", bundle: .module)
            case .busy: return DeviceControlError.busy.localizedDescription
            case .closed: return String(localized: "device.backend.closed", defaultValue: "The device connection is closed.", bundle: .module)
            case .transport(let code): return String(localized: "device.backend.transport-failed", defaultValue: "The device connection failed (\(String(describing: code))). Check the VPN and system pairing authorization.", bundle: .module)
            default: return String(localized: "device.backend.invalid-state", defaultValue: "The device backend is in an invalid state. Connect again.", bundle: .module)
            }
        }
        return String(localized: "device.operation.failed", defaultValue: "The device operation failed. Check local network permission, VPN configuration, and system pairing authorization.", bundle: .module)
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
