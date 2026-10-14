// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CNCMBackend
import CEiscueAutomation

/// Existing, authorized RemotePairing identity only. No filesystem/Keychain
/// discovery, generation or conversion from a Lockdown record is performed.
public struct AuthorizedRemoteIdentity {
    public var signingSeed: Data
    public let controllerID: String
    public let peerID: String
    public let peerPublicKey: Data
    public let alternateIRK: Data
    public let peerUDID: String
    public let peerModel: String
    public init(signingSeed: Data, controllerID: String, peerID: String, peerPublicKey: Data,
                alternateIRK: Data, peerUDID: String, peerModel: String) throws {
        guard signingSeed.count == 32, peerPublicKey.count == 32, alternateIRK.count == 16,
              [controllerID, peerID, peerUDID, peerModel].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) else { throw NativeBackendError.invalidIdentity }
        self.signingSeed = signingSeed; self.controllerID = controllerID; self.peerID = peerID
        self.peerPublicKey = peerPublicKey; self.alternateIRK = alternateIRK; self.peerUDID = peerUDID; self.peerModel = peerModel
    }
    /// Best-effort clearing of this owned Data value; callers must also dispose
    /// of their original copies. No claim that Swift eliminates every COW copy.
    public mutating func clearSeed() { signingSeed.resetBytes(in: signingSeed.startIndex..<signingSeed.endIndex); signingSeed.removeAll() }
}
public struct ExistingSessionAuthorization {
    public let verifyExistingIdentity: Bool
    public let screen: Bool
    public let screenVideoStream: Bool
    public let input: Bool
    public init(verifyExistingIdentity: Bool, screen: Bool = false, screenVideoStream: Bool = false, input: Bool = false) {
        self.verifyExistingIdentity = verifyExistingIdentity; self.screen = screen
        self.screenVideoStream = screenVideoStream; self.input = input
    }
    var mask: UInt32 { (screen ? 1 : 0) | (screenVideoStream ? 2 : 0) | (input ? 4 : 0) | (verifyExistingIdentity ? 8 : 0) }
}
public enum NativeBackendError: Error, Equatable {
    case invalidIdentity, authorizationRequired, unsupportedABI, invalidCandidate, busy, closed, malformedEvent
    case coordinateSpaceChanged, unsupportedControlAction
    case automationDeliveryUnknown(cause: UInt32), automationAuthorizationTimedOut
    case transport(code: Int32)
    /// Numeric protocol categories only; never raw peer data or keys.
    case protocolFailure(stage: UInt32, cause: UInt32)
    case touchPreparationFailure(stage: UInt32, cause: UInt32)
    case applicationQueryFailure(stage: UInt32, cause: UInt32)
    case screenshotFailure(stage: UInt32, cause: UInt32)
}
public enum InputDelivery: Sendable { case reportsWrittenVisualEffectUnverified }

/// An opaque coordinate-space identity. A return to the same dimensions after
/// rotation/reset receives a different ID; dimensions alone cannot authorize input.
public struct NativeVideoGeometry: Sendable, Equatable {
    public let id: UUID
    public let epoch: UInt64
    public let revision: UInt64
}

public struct NativeVideoSnapshot: Sendable {
    public let data: Data
    public let geometry: NativeVideoGeometry
    public let mimeType: String
    public init(data: Data, geometry: NativeVideoGeometry, mimeType: String = "image/jpeg") {
        self.data = data; self.geometry = geometry; self.mimeType = mimeType
    }
}
public enum NativeControlAction: String, Sendable, CaseIterable {
    case screenshot, tap, swipe, textInput, launchApplication, home, listApplications
}

/// Owns one native worker, its two relay streams and media. The caller closes
/// on explicit stop, execution expiry or disconnect, rather than app visibility.
/// Initializer is idle and never imports credentials.
@MainActor public final class NativeDeveloperServices: DeveloperServices {
    public static var linkedABIVersion: UInt32 { ncm_backend_abi() }
    private var handle: UInt64 = 0
    private var serial: UInt64 = 0
    private var busy = false
    private var ready = false
    private var services: [String] = []
    private var videoPollSerial: UInt64 = 0
    private var videoPump: Task<Void, Never>?
    private var videoDecoder: NCMVideoDecoder?
    public private(set) var videoSnapshotDiagnostics: String?
    private var videoDecodeFailure: NativeBackendError?
    private var mediaStartCompleted = false
    private var automationLease: UInt64 = 0
    private var automationLayout: NCMXCTestLayout?
    private var automationGeometry = NCMXCTestGeometryTracker()
    private var automationRequest: UInt64 = 0
    private var automationStopping = false
    private var ownsXCTestChannels = false
    private var automationStopConfirmed = false
    private static var usesOwnedXCTest: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
        #else
        false
        #endif
    }
    public var supportedControlActions: Set<NativeControlAction> {
        guard mediaStartCompleted else { return [] }
        return Set(NativeControlAction.allCases)
    }
    public init() {}
    deinit {
        videoPump?.cancel()
        let lease = automationLease
        if lease != 0 {
            if Thread.isMainThread { eiscue_automation_abort(lease) }
            else { DispatchQueue.main.async { eiscue_automation_abort(lease) } }
        }
        if handle != 0 { ncm_backend_close(handle) }
    }
    public func close() {
        if automationLease != 0 { eiscue_automation_abort(automationLease) }
        automationLease = 0; automationLayout = nil; automationGeometry.reset()
        ownsXCTestChannels = false
        videoPump?.cancel(); videoPump = nil
        videoDecoder = nil; videoDecodeFailure = nil; mediaStartCompleted = false
        let old = handle; handle = 0; ready = false; services = []
        if old != 0 { ncm_backend_close(old) }
    }
    /// Caller must refresh discovery just before this call (candidate TTL).
    /// Compatibility entry point for USB. Prefer the scoped discovery overload.
    public func connect(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                        discovery: DiagnosticReply, endpoint: DiagnosticReply.Endpoint) async throws {
        try Task.checkCancellation()
        guard authorization.verifyExistingIdentity else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard Self.linkedABIVersion == NCM_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        let binding = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory(), transport: .usb)
        try await connect(identity: identity, authorization: authorization,
                          discovery: discovery, endpoint: endpoint, binding: binding)
    }
    private func connect(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                         discovery: DiagnosticReply, endpoint: DiagnosticReply.Endpoint,
                         binding: NCMInterfaceBinding) async throws {
        try Task.checkCancellation()
        guard authorization.verifyExistingIdentity else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard Self.linkedABIVersion == NCM_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        guard discovery.layer == "discovery", discovery.result == "candidates", !discovery.authenticated,
              discovery.screenCaptured != true, discovery.inputExecuted != true,
              let generation = discovery.generation, generation > 0, endpoint.service == "remotepairing",
              discovery.endpoints?.contains(where: { $0.index == endpoint.index && $0.family == endpoint.family && $0.port == endpoint.port && $0.service == endpoint.service }) == true else { throw NativeBackendError.invalidCandidate }
        try binding.validateCurrent()
        let row = binding.row
        var config = ncm_config(abi: 1, interface_index: row.index, generation: generation, endpoint_index: UInt32(endpoint.index), permissions: authorization.mask)
        let values = [identity.signingSeed, Data(identity.controllerID.utf8), Data(identity.peerID.utf8), identity.peerPublicKey,
                      identity.alternateIRK, Data(identity.peerUDID.utf8), Data(identity.peerModel.utf8)]
        var started: UInt64 = 0
        let code = withSlices(values) { b in
            var raw = ncm_identity(seed: b[0], controller_id: b[1], peer_id: b[2], peer_public_key: b[3], alt_irk: b[4], peer_udid: b[5], peer_model: b[6])
            return ncm_backend_start(&config, &raw, &started)
        }
        guard code == 0, started != 0 else { throw NativeBackendError.transport(code: code) }
        handle = started
        try await finishConnect(started)
    }
    /// Preferred scoped path. Rejects expired discovery and interface changes
    /// before importing the identity into the native transport worker.
    public func connect(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                        discovery: NCMDiscoveredEndpoint) async throws {
        try Task.checkCancellation()
        let binding = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory(), transport: discovery.transport)
        try discovery.validate(currentInterface: binding.row, transport: binding.transport)
        try await connect(identity: identity, authorization: authorization,
                          discovery: discovery.reply, endpoint: discovery.endpoint, binding: binding)
    }
    /// Reuses the exact authenticated CoreDevice session over a bound local VPN socket.
    public func connectLocalVPN(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                                pairingPort: UInt16, configuration: VPNLoopbackConfiguration = .defaults) async throws {
        try Task.checkCancellation()
        guard authorization.verifyExistingIdentity else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard Self.linkedABIVersion == NCM_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        guard pairingPort != 0 else { throw NativeBackendError.invalidCandidate }
        let row = try LocalVPNDiscovery.selectInterface(NCMInterfaceBinding.inventory(), configuration: configuration)
        let values = [identity.signingSeed, Data(identity.controllerID.utf8), Data(identity.peerID.utf8), identity.peerPublicKey,
                      identity.alternateIRK, Data(identity.peerUDID.utf8), Data(identity.peerModel.utf8)]
        var started: UInt64 = 0
        let code = withSlices(values) { b in
            var raw = ncm_identity(seed: b[0], controller_id: b[1], peer_id: b[2], peer_public_key: b[3], alt_irk: b[4], peer_udid: b[5], peer_model: b[6])
            return ncm_local_vpn_start_configured(row.index, pairingPort, authorization.mask, configuration.localIPv4, configuration.peerIPv4, &raw, &started)
        }
        guard code == 0, started != 0 else { throw NativeBackendError.transport(code: code) }
        handle = started
        try await finishConnect(started)
    }
    private func finishConnect(_ token: UInt64) async throws {
        busy = true; defer { busy = false }
        do {
            let (header, data) = try await receive(token, requestID: 0)
            guard header.kind == 1, data.count <= 256 * 1024,
                  let names = try? JSONDecoder().decode([String].self, from: data), names.count <= 4096 else { throw NativeBackendError.malformedEvent }
            services = names; ready = true
        } catch { if handle == token { close() }; throw error }
    }
    public func listServices() async throws -> [String] {
        guard ready, handle != 0 else { throw NativeBackendError.closed }; return services
    }
    public func checkDeveloperReadiness() async throws { _ = try await operation(1) }
    public func capturePNG() async throws -> Data {
        try await operation(Self.usesOwnedXCTest ? UInt32(NCM_ACTION_LEGACY_SCREENSHOT) : 2, expectedKind: 4)
    }
    /// Starts an authenticated screen video stream; packets are drained locally.
    public func startTouchMedia() async throws {
        if Self.usesOwnedXCTest { try await startOwnedAutomation(); return }
        _ = try await operation(3)
        mediaStartCompleted = true
        videoPump?.cancel()
        let decoder = NCMVideoDecoder()
        videoDecoder = decoder; videoDecodeFailure = nil
        let token = handle
        videoPump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let consumed: Bool
                do {
                    guard let self, self.handle == token, self.videoDecoder === decoder else { return }
                    consumed = try await self.receiveVideoPicture(token: token, decoder: decoder)
                    self.videoPollSerial &+= 1
                } catch is CancellationError { return }
                catch {
                    if let self, self.handle == token, self.videoDecoder === decoder {
                        self.videoDecodeFailure = .screenshotFailure(stage: 20, cause: 1)
                    }
                    return
                }
                // Do not retain the service across the idle wait.
                if !consumed { do { try await Task.sleep(for: .milliseconds(5)) } catch { return } }
            }
        }
    }
    /// Stop local observation, then release this controller's owned automation
    /// or DisplayService/HID resources without revoking the authentication tunnel.
    public func stopTouchMedia() async throws {
        if Self.usesOwnedXCTest { try await stopOwnedAutomation(); return }
        videoPump?.cancel(); videoPump = nil
        let decoder = videoDecoder; videoDecoder = nil; videoDecodeFailure = nil
        _ = try await operation(11)
        mediaStartCompleted = false
        if let decoder { await decoder.reset() }
    }
    /// Eiscue shutdown: stop local observation immediately, then let the current
    /// request drain before sending this session's explicit media-stop request.
    /// The caller owns the outer deadline and always calls close afterwards.
    public func stopTouchMediaWhenIdle() async throws -> Bool {
        if Self.usesOwnedXCTest { automationStopping = true }
        defer { automationStopping = false }
        videoPump?.cancel(); videoPump = nil
        videoDecoder = nil; videoDecodeFailure = nil
        while busy {
            try Task.checkCancellation()
            guard handle != 0 else { throw NativeBackendError.closed }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        let hadConfirmedStart = mediaStartCompleted
        try await stopTouchMedia()
        return Self.usesOwnedXCTest ? automationStopConfirmed : hadConfirmedStart
    }
    /// Snapshot the continuously decoded video picture, independent of input history.
    public func captureVideoJPEG() async throws -> Data {
        let snapshot = try await captureVideoJPEGWithGeometry()
        guard snapshot.mimeType != "image/jpeg" else { return snapshot.data }
        guard let source = CGImageSourceCreateWithData(snapshot.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NativeBackendError.malformedEvent }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { throw NativeBackendError.malformedEvent }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NativeBackendError.malformedEvent }
        return output as Data
    }
    /// A fresh screenshot and its coordinate-space identity. iOS 26 returns PNG;
    /// DisplayService returns JPEG. Callers must use the snapshot's MIME type.
    public func captureVideoJPEGWithGeometry() async throws -> NativeVideoSnapshot {
        if Self.usesOwnedXCTest { return try await captureOwnedAutomationSnapshot() }
        guard ready, handle != 0, let decoder = videoDecoder else { throw NativeBackendError.closed }
        videoSnapshotDiagnostics = nil
        let token = handle, began = ContinuousClock.now
        var initial = ncm_video_status()
        let initialCode = ncm_backend_video_get_status(token, &initial)
        var initialSnapshot = ncm_video_snapshot()
        guard ncm_backend_video_get_snapshot(token, &initialSnapshot) == 0 else { throw NativeBackendError.closed }
        let polledAfter = videoPollSerial
        let deadline = began.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard token == handle, ready else { throw NativeBackendError.closed }
            // The single video pump owns polling and preserves the reference chain.
            // Reject cached pixels while a new generation reset is pending.
            await Task.yield()
            guard token == handle, ready else { throw NativeBackendError.closed }
            guard videoDecoder === decoder else { throw NativeBackendError.closed }
            var snapshot = ncm_video_snapshot()
            guard ncm_backend_video_get_snapshot(token, &snapshot) == 0 else { throw NativeBackendError.closed }
            // A new decoded picture, or a post-request report confirming that all
            // emitted packets form the already decoded picture. Picture age alone
            // says nothing about a static display; no input-history dependency.
            let confirmed = snapshot.report > initialSnapshot.report ? snapshot.serial : 0
            if videoPollSerial != polledAfter,
               let image = try await decoder.jpegWithGeometry(notBefore: began, confirmedEpoch: snapshot.epoch, confirmedSerial: confirmed) {
                guard token == handle, ready else { throw NativeBackendError.closed }
                var after = ncm_video_snapshot()
                guard ncm_backend_video_get_snapshot(token, &after) == 0 else { throw NativeBackendError.closed }
                if after.epoch != snapshot.epoch || after.epoch != image.geometry.epoch { continue }
                videoDecodeFailure = nil
                videoSnapshotDiagnostics = "screenshot.video received=true decoder=\(await decoder.diagnosticStatus())"
                return image
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        var status = ncm_video_status()
        let code = ncm_backend_video_get_status(token, &status)
        NSLog("NCM screenshot timeout status=%d datagrams=%llu rtp=%llu rejected=%llu frames=%llu discontinuities=%llu overflows=%llu refreshes=%llu sourcePort=%llu", code, status.datagrams, status.rtp, status.rejected, status.frames, status.discontinuities, status.overflows, status.refreshes, status.source_port)
        let diagnostics = "screenshot.video timeout=true datagrams=\(status.datagrams) rtp=\(status.rtp) frames=\(status.frames) refreshes=\(status.refreshes) intervalDatagrams=\(status.datagrams &- initial.datagrams) intervalFrames=\(status.frames &- initial.frames) decoder=\(await decoder.diagnosticStatus())"
        videoSnapshotDiagnostics = diagnostics
        NSLog("NCM %@", diagnostics)
        if let videoDecodeFailure { throw videoDecodeFailure }
        // Historical overload is diagnostic history, not the cause of every later failure.
        let cause = code == 0 ? NCMVideoSnapshotFailure.timeoutCause(datagrams: status.datagrams, rtp: status.rtp, frames: status.frames, overflows: status.overflows, initialOverflows: initialCode == 0 ? initial.overflows : 0) : UInt32(2)
        throw NativeBackendError.screenshotFailure(stage: 20, cause: cause)
    }
    /// Lightweight input guard: never compresses another image. Unknown/pending
    /// geometry fails closed, including a reset not yet consumed by the video pump.
    public func currentVideoGeometry() async throws -> NativeVideoGeometry? {
        if Self.usesOwnedXCTest { return try await currentOwnedAutomationGeometry() }
        guard ready, handle != 0, let decoder = videoDecoder else { throw NativeBackendError.closed }
        let token = handle, deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        repeat {
            try Task.checkCancellation()
            guard token == handle, ready, videoDecoder === decoder else { throw NativeBackendError.closed }
            var before = ncm_video_snapshot()
            guard ncm_backend_video_get_snapshot(token, &before) == 0 else { throw NativeBackendError.closed }
            let state = await decoder.currentGeometry()
            try Task.checkCancellation()
            guard token == handle, ready, videoDecoder === decoder else { throw NativeBackendError.closed }
            var after = ncm_video_snapshot()
            guard ncm_backend_video_get_snapshot(token, &after) == 0 else { throw NativeBackendError.closed }
            if let state,
               before.epoch == after.epoch, state.geometry.epoch == after.epoch,
               before.serial > 0, after.serial > 0,
               state.serial >= before.serial, state.serial >= after.serial {
                return state.geometry
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return nil
    }
    private func receiveVideoPicture(token: UInt64, decoder: NCMVideoDecoder) async throws -> Bool {
        var header = ncm_event()
        var status = ncm_backend_video_poll(token, &header, nil, 0)
        if status == 4 { return false }
        if status == 3 { throw NativeBackendError.closed }
        if status == 0, header.kind == 14 { await decoder.reset(); return true }
        guard status == 5, header.kind == 13, header.size >= 64, header.size <= 8 * 1024 * 1024 else {
            throw NativeBackendError.screenshotFailure(stage: 20, cause: 1)
        }
        var data = Data(count: header.size)
        status = data.withUnsafeMutableBytes { ncm_backend_video_poll(token, &header, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        if status == 0, header.kind == 14 { await decoder.reset(); return true }
        // A newer independent picture can replace the size-probed one.
        if status == 4 || status == 5 { return false }
        if status == 3 { throw NativeBackendError.closed }
        guard status == 0, header.kind == 13, header.size >= 64, header.size <= data.count else {
            throw NativeBackendError.screenshotFailure(stage: 20, cause: 1)
        }
        if header.size < data.count { data.removeSubrange(header.size..<data.count) }
        do {
            let decoded = try await decoder.consume(data)
            guard handle == token, ready, videoDecoder === decoder else { throw NativeBackendError.closed }
            if decoded { videoDecodeFailure = nil }
        } catch {
            try Task.checkCancellation()
            guard handle == token, ready, videoDecoder === decoder else { throw NativeBackendError.closed }
            videoDecodeFailure = (error as? NativeBackendError) ?? .screenshotFailure(stage: 20, cause: 1)
            NSLog("NCM screenshot decode failed: %@", String(describing: error))
            await decoder.reset()
            _ = ncm_backend_video_refresh(token)
        }
        return true
    }
    #if DEBUG
    /// Explicit developer probe only; no automatic persistence or network upload.
    public func videoDiagnosticKeyframe() async -> Data? { await videoDecoder?.diagnosticKeyframe() }
    #endif
    public func tapDelivery(x: UInt16, y: UInt16) async throws -> InputDelivery {
        if Self.usesOwnedXCTest { return try await deliverOwnedTouch(x: x, y: y, endX: x, endY: y, durationMS: 0) }
        _ = try await operation(4, x: x, y: y); return .reportsWrittenVisualEffectUnverified
    }
    public func tap(x: UInt16, y: UInt16) async throws { _ = try await tapDelivery(x: x, y: y) }
    public func dragDelivery(fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16) async throws -> InputDelivery {
        guard (100...2000).contains(durationMS) else { throw NativeBackendError.malformedEvent }
        if Self.usesOwnedXCTest { return try await deliverOwnedTouch(x: fromX, y: fromY, endX: toX, endY: toY, durationMS: durationMS) }
        _ = try await operation(6, x: fromX, y: fromY, drag: (toX, toY, durationMS))
        return .reportsWrittenVisualEffectUnverified
    }
    public func home() async throws {
        if Self.usesOwnedXCTest {
            guard mediaStartCompleted else { throw NativeBackendError.closed }
            guard supportedControlActions.contains(.home) else { throw NativeBackendError.unsupportedControlAction }
            _ = try await deliverOwnedNonCoordinate(text: nil); return
        }
        _ = try await operation(7)
    }
    public func installedApplications() async throws -> Data { try await operation(8, expectedKind: 11) }
    public func launchApplication(bundleID: String, arguments: [String]) async throws {
        _ = try await operation(9, payload: JSONSerialization.data(withJSONObject: ["bundle_id": bundleID, "arguments": arguments]))
    }
    public func typeText(_ text: String) async throws {
        if Self.usesOwnedXCTest {
            guard mediaStartCompleted else { throw NativeBackendError.closed }
            guard supportedControlActions.contains(.textInput) else { throw NativeBackendError.unsupportedControlAction }
            guard !text.isEmpty, text.utf8.count <= 8192, !text.utf8.contains(0) else { throw NativeBackendError.malformedEvent }
            _ = try await deliverOwnedNonCoordinate(text: Data(text.utf8)); return
        }
        _ = try await operation(10, payload: JSONSerialization.data(withJSONObject: ["text": text]))
    }
    func operation(_ action: UInt32, x: UInt16 = 0, y: UInt16 = 0, expectedKind: UInt32 = 2, drag: (UInt16, UInt16, UInt16)? = nil, payload: Data? = nil) async throws -> Data {
        guard !busy else { throw NativeBackendError.busy }
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false }
        return try await performOperation(action, x: x, y: y, expectedKind: expectedKind, drag: drag, payload: payload)
    }
    /// Called only while the public operation holds the session's busy lease.
    private func performOperation(_ action: UInt32, x: UInt16 = 0, y: UInt16 = 0, expectedKind: UInt32 = 2,
                                  drag: (UInt16, UInt16, UInt16)? = nil, payload: Data? = nil) async throws -> Data {
        let token = handle
        guard ready, token != 0 else { throw NativeBackendError.closed }
        serial += 1; let id = serial
        do {
            try Task.checkCancellation()
            let code: Int32
            if action == UInt32(NCM_ACTION_XCTEST_START), let payload {
                code = withSlices([payload]) { ncm_backend_xctest_start(token, id, $0[0]) }
            } else if action == UInt32(NCM_ACTION_XCTEST_STOP) { code = ncm_backend_xctest_stop(token, id) }
            else if let payload { code = withSlices([payload]) { ncm_backend_command(token, id, action, $0[0]) } }
            else if let drag { code = ncm_backend_drag(token, id, x, y, drag.0, drag.1, drag.2) }
            else { code = ncm_backend_submit(token, id, action, x, y) }
            guard code == 0 else { throw NativeBackendError.transport(code: code) }
            let (header, data) = try await receive(token, requestID: id)
            guard header.kind == expectedKind else { throw NativeBackendError.malformedEvent }
            return data
        } catch {
            #if DEBUG
            operationDiagnostic(error, action: action)
            #endif
            // A screenshot owns a fresh, read-only service stream. Dropping that
            // stream does not revoke the authenticated tunnel or replay any input.
            // Cancellation, worker closure and malformed ABI events remain fatal.
            if [UInt32(2), UInt32(NCM_ACTION_LEGACY_SCREENSHOT)].contains(action),
               case NativeBackendError.protocolFailure(let stage, let cause) = error,
               [UInt32(9), 19, 20, 22, 23, 24, 25].contains(stage) {
                throw NativeBackendError.screenshotFailure(stage: stage, cause: cause)
            }
            if action == UInt32(NCM_ACTION_XCTEST_START), case NativeBackendError.protocolFailure(let stage, let cause) = error {
                // Rust has dropped all partial XCTest children; preserve the parent
                // so explicit owned-session stop can acknowledge cleanup.
                throw NativeBackendError.touchPreparationFailure(stage: stage, cause: cause)
            }
            if case NativeBackendError.touchPreparationFailure = error { throw error }
            if case NativeBackendError.applicationQueryFailure = error { throw error }
            if handle == token { close() }; throw error
        }
    }
    #if DEBUG
    private func automationDiagnostic(_ message: String) {
        // Callers supply only allowlisted state labels and numeric categories.
        print(message)
        fflush(stdout)
    }
    private func operationDiagnostic(_ error: Error, action: UInt32) {
        switch error {
        case NativeBackendError.protocolFailure(let stage, let cause),
             NativeBackendError.touchPreparationFailure(let stage, let cause),
             NativeBackendError.screenshotFailure(let stage, let cause):
            automationDiagnostic("NCM operation failed action=\(action) stage=\(stage) cause=\(cause)")
        case NativeBackendError.transport(let code):
            automationDiagnostic("NCM operation failed action=\(action) transportCode=\(code)")
        case NCMError.timeout:
            automationDiagnostic("NCM operation failed action=\(action) receiveTimedOut=true")
        default:
            automationDiagnostic("NCM operation failed action=\(action) canceled=\(error is CancellationError)")
        }
    }
    #endif
    private func startOwnedAutomation() async throws {
        try Task.checkCancellation()
        guard !busy, !automationStopping, automationLease == 0, !ownsXCTestChannels else { throw NativeBackendError.busy }
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false }
        automationStopConfirmed = false
        let token = handle, sessionID = UUID()
        var bytes = sessionID.uuid
        let uuidData = withUnsafeBytes(of: &bytes) { Data($0) }
        #if DEBUG
        automationDiagnostic("NCM owned XCTest start=true")
        #endif
        let receipt = try await performOperation(UInt32(NCM_ACTION_XCTEST_START), payload: uuidData)
        ownsXCTestChannels = true
        do { try NCMXCTestAuthorization.validate(receipt, sessionID: sessionID, processID: getpid()) }
        catch {
            #if DEBUG
            automationDiagnostic("NCM owned XCTest authorizedReceiptValid=false")
            #endif
            throw error
        }
        #if DEBUG
        automationDiagnostic("NCM owned XCTest authorized=true")
        #endif
        guard handle == token else { throw NativeBackendError.closed }
        var lease: UInt64 = 0
        let code = uuidData.withUnsafeBytes { eiscue_automation_begin($0.bindMemory(to: UInt8.self).baseAddress, &lease) }
        #if DEBUG
        automationDiagnostic("NCM owned automation beginCode=\(code) leaseCreated=\(lease != 0)")
        #endif
        if lease != 0 { automationLease = lease }
        guard code == 0, lease != 0 else { throw automationPreparationError(code) }
        _ = try await waitForAutomation(lease: lease, token: token, timeout: .seconds(60))
        try Task.checkCancellation()
        guard handle == token, automationLease == lease, !automationStopping else { throw NativeBackendError.closed }
        mediaStartCompleted = true
    }
    private func stopOwnedAutomation() async throws {
        guard !busy else { throw NativeBackendError.busy }
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false }
        automationStopConfirmed = false
        let token = handle, lease = automationLease
        automationLayout = nil; automationGeometry.reset()
        if lease != 0 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var code = eiscue_automation_stop(lease)
            while code == EISCUE_AUTOMATION_BUSY, ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard handle == token else { throw NativeBackendError.closed }
                try await Task.sleep(for: .milliseconds(20))
                code = eiscue_automation_stop(lease)
            }
            guard code == 0 else {
                eiscue_automation_abort(lease); automationLease = 0
                throw NativeBackendError.automationDeliveryUnknown(cause: UInt32(max(code, 1)))
            }
            automationLease = 0
        }
        // Idempotent stop also acknowledges cleanup after partial preparation.
        _ = try await performOperation(UInt32(NCM_ACTION_XCTEST_STOP))
        guard handle == token else { throw NativeBackendError.closed }
        ownsXCTestChannels = false; mediaStartCompleted = false; automationStopConfirmed = true
    }
    private func automationPreparationError(_ code: Int32) -> NativeBackendError {
        .touchPreparationFailure(stage: 38, cause: UInt32(max(code, 1)))
    }
    private func automationState(lease: UInt64, token: UInt64) throws -> eiscue_automation_state {
        guard ready, handle == token, automationLease == lease, lease != 0 else { throw NativeBackendError.closed }
        var state = eiscue_automation_state()
        let code = eiscue_automation_poll(lease, &state)
        guard code == 0 else { throw automationPreparationError(code) }
        return state
    }
    private func waitForAutomation(lease: UInt64, token: UInt64, timeout: Duration) async throws -> eiscue_automation_state {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        #if DEBUG
        var previousPhase: UInt32?
        var savedPreparationFrame = false
        #endif
        repeat {
            try Task.checkCancellation()
            let state = try automationState(lease: lease, token: token)
            #if DEBUG
            if previousPhase != state.phase {
                automationDiagnostic("NCM owned automation phase=\(state.phase) error=\(state.error)")
                previousPhase = state.phase
            }
            // Explicit developer proof only: one read-only frame of the setup
            // state, so a system prompt is observed rather than inferred.
            if !savedPreparationFrame, state.phase == UInt32(EISCUE_AUTOMATION_AUTHORIZING),
               ProcessInfo.processInfo.arguments.contains("--owned-device-check") {
                savedPreparationFrame = true
                do {
                    try await Task.sleep(for: .seconds(2))
                    let png = try await performOperation(UInt32(NCM_ACTION_LEGACY_SCREENSHOT), expectedKind: 4)
                    try png.write(to: URL.cachesDirectory.appendingPathComponent("EiscueOwnedPreparation.png"), options: [.atomic, .completeFileProtection])
                    print("NCM owned preparation frameSaved=true"); fflush(stdout)
                } catch { print("NCM owned preparation frameSaved=false"); fflush(stdout) }
            }
            #endif
            switch state.phase {
            case UInt32(EISCUE_AUTOMATION_READY):
                _ = try NCMXCTestScreenState(state)
                return state
            case UInt32(EISCUE_AUTOMATION_PREPARING), UInt32(EISCUE_AUTOMATION_QUERYING), UInt32(EISCUE_AUTOMATION_AUTHORIZING): break
            case UInt32(EISCUE_AUTOMATION_FAILED): throw automationPreparationError(Int32(clamping: state.error))
            case UInt32(EISCUE_AUTOMATION_STOPPED): throw NativeBackendError.closed
            default: throw NativeBackendError.malformedEvent
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        var snapshot = eiscue_automation_state()
        let code = eiscue_automation_poll(lease, &snapshot)
        #if DEBUG
        automationDiagnostic("NCM owned automation timedOut=true pollCode=\(code) phase=\(snapshot.phase) error=\(snapshot.error)")
        #endif
        if code == 0, snapshot.phase == UInt32(EISCUE_AUTOMATION_AUTHORIZING) {
            throw NativeBackendError.automationAuthorizationTimedOut
        }
        throw NativeBackendError.touchPreparationFailure(stage: 38, cause: 14)
    }
    private func refreshOwnedScreen(lease: UInt64, token: UInt64) async throws -> NCMXCTestScreenState {
        let code = eiscue_automation_refresh_geometry(lease)
        guard code == 0 else { throw automationPreparationError(code) }
        return try NCMXCTestScreenState(await waitForAutomation(lease: lease, token: token, timeout: .seconds(5)))
    }
    private func captureOwnedAutomationSnapshot() async throws -> NativeVideoSnapshot {
        try Task.checkCancellation()
        guard !busy, !automationStopping else { throw NativeBackendError.busy }
        guard mediaStartCompleted, automationLease != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false }
        let token = handle, lease = automationLease
        automationLayout = nil; automationGeometry.reset()
        let before = try await refreshOwnedScreen(lease: lease, token: token)
        let encodedPNG = try await captureOwnedPNG(lease: lease, token: token, revision: before.revision)
        let after = try await refreshOwnedScreen(lease: lease, token: token)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--owned-device-check") {
            automationDiagnostic("NCM owned geometry beforeRevision=\(before.revision) afterRevision=\(after.revision) beforeOrientation=\(before.orientation) afterOrientation=\(after.orientation) scale=\(after.scale) boundsWidth=\(after.boundsWidth) boundsHeight=\(after.boundsHeight)")
            if let source = CGImageSourceCreateWithData(encodedPNG as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                automationDiagnostic("NCM owned PNG width=\(width) height=\(height) encodedOrientation=\(properties[kCGImagePropertyOrientation] as? Int ?? 1)")
            }
        }
        #endif
        guard before == after else { throw NativeBackendError.coordinateSpaceChanged }
        let png = try NCMXCTestImage.uprightPNG(encodedPNG)
        let layout = try NCMXCTestLayout(png: png, screen: after)
        automationLayout = layout
        let geometry = automationGeometry.update(lease: lease, layout: layout)
        videoSnapshotDiagnostics = "screenshot.xctest received=true geometryValidated=true"
        return NativeVideoSnapshot(data: png, geometry: geometry, mimeType: "image/png")
    }
    private func captureOwnedPNG(lease: UInt64, token: UInt64, revision: UInt64) async throws -> Data {
        automationRequest += 1
        let request = automationRequest
        let started = eiscue_automation_screenshot(lease, request, revision)
        guard started == 0 else { throw ownedScreenshotError(started) }
        defer { eiscue_automation_cancel_screenshot(lease, request) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        repeat {
            try Task.checkCancellation()
            guard ready, handle == token, automationLease == lease else { throw NativeBackendError.closed }
            var length = 0
            let code = eiscue_automation_copy_screenshot(lease, request, nil, 0, &length)
            if code == 0 {
                guard (8...64 * 1024 * 1024).contains(length) else { throw NativeBackendError.screenshotFailure(stage: 39, cause: 1) }
                var data = Data(count: length)
                let copied = data.withUnsafeMutableBytes {
                    eiscue_automation_copy_screenshot(lease, request, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &length)
                }
                guard copied == 0 else { throw ownedScreenshotError(copied) }
                guard length == data.count else { throw NativeBackendError.screenshotFailure(stage: 39, cause: 1) }
                return data
            }
            guard code == EISCUE_AUTOMATION_BUSY else { throw ownedScreenshotError(code) }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw NativeBackendError.screenshotFailure(stage: 39, cause: 14)
    }
    private func ownedScreenshotError(_ code: Int32) -> NativeBackendError {
        if code == EISCUE_AUTOMATION_GEOMETRY { return .coordinateSpaceChanged }
        if code == EISCUE_AUTOMATION_CLOSED { return .closed }
        return .screenshotFailure(stage: 39, cause: UInt32(max(code, 1)))
    }
    private func currentOwnedAutomationGeometry() async throws -> NativeVideoGeometry? {
        try Task.checkCancellation()
        guard !busy, !automationStopping else { throw NativeBackendError.busy }
        guard mediaStartCompleted, automationLease != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false }
        let token = handle, lease = automationLease
        let screen = try await refreshOwnedScreen(lease: lease, token: token)
        guard let layout = automationLayout, screen == layout.screen else {
            automationLayout = nil; automationGeometry.reset(); return nil
        }
        return automationGeometry.current
    }
    private func deliverOwnedTouch(x: UInt16, y: UInt16, endX: UInt16, endY: UInt16, durationMS: UInt16) async throws -> InputDelivery {
        try Task.checkCancellation()
        guard !busy, !automationStopping else { throw NativeBackendError.busy }
        guard mediaStartCompleted, automationLease != 0 else { throw NativeBackendError.closed }
        guard let layout = automationLayout else { throw NativeBackendError.coordinateSpaceChanged }
        busy = true; defer { busy = false }
        let token = handle, lease = automationLease
        let screen = try await refreshOwnedScreen(lease: lease, token: token)
        guard screen == layout.screen else {
            automationLayout = nil; automationGeometry.reset(); throw NativeBackendError.coordinateSpaceChanged
        }
        try Task.checkCancellation()
        // Consume before submission, including every failure. Never replay an event.
        automationLayout = nil; automationGeometry.reset()
        automationRequest += 1
        let request = automationRequest
        let code = eiscue_automation_touch(lease, request, screen.revision, UInt32(layout.width), UInt32(layout.height),
                                           x, y, endX, endY, durationMS)
        try checkAutomationSubmission(code)
        return try await awaitOwnedDelivery(lease: lease, token: token, request: request)
    }
    /// Delivers Home or text through the owned iOS 26 XCTest session, with the
    /// same bounded receipt and no-replay rules as touch input.
    private func deliverOwnedNonCoordinate(text: Data?) async throws -> InputDelivery {
        try Task.checkCancellation()
        guard !busy, !automationStopping else { throw NativeBackendError.busy }
        guard mediaStartCompleted, automationLease != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false }
        let token = handle, lease = automationLease
        automationLayout = nil; automationGeometry.reset()
        let screen = try await refreshOwnedScreen(lease: lease, token: token)
        try Task.checkCancellation()
        automationRequest += 1; let request = automationRequest
        let code: Int32
        if let text {
            code = text.withUnsafeBytes { eiscue_automation_type_text(lease, request, screen.revision,
                $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        } else { code = eiscue_automation_home(lease, request, screen.revision) }
        try checkAutomationSubmission(code)
        // Whole-text paste uses a single bounded key event. A delivered shortcut
        // still requires a screenshot to confirm focus, paste consent and content.
        return try await awaitOwnedDelivery(lease: lease, token: token, request: request)
    }
    private func checkAutomationSubmission(_ code: Int32) throws {
        if code == EISCUE_AUTOMATION_GEOMETRY { throw NativeBackendError.coordinateSpaceChanged }
        if code == EISCUE_AUTOMATION_BUSY { throw NativeBackendError.busy }
        guard code == 0 else { throw NativeBackendError.automationDeliveryUnknown(cause: UInt32(max(code, 1))) }
    }
    private func awaitOwnedDelivery(lease: UInt64, token: UInt64, request: UInt64, timeout: Duration = .seconds(15)) async throws -> InputDelivery {
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            repeat {
                try Task.checkCancellation()
                let state = try automationState(lease: lease, token: token)
                guard state.request_id == request else { throw NativeBackendError.malformedEvent }
                if state.phase == UInt32(EISCUE_AUTOMATION_READY) { return .reportsWrittenVisualEffectUnverified }
                guard state.phase == UInt32(EISCUE_AUTOMATION_DELIVERING) else {
                    throw NativeBackendError.automationDeliveryUnknown(cause: max(state.error, 1))
                }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            throw NativeBackendError.automationDeliveryUnknown(cause: 14)
        } catch {
            if handle == token { close() }
            throw NativeBackendError.automationDeliveryUnknown(cause: (error as? NativeBackendError).flatMap {
                if case .automationDeliveryUnknown(let cause) = $0 { return cause }; return nil
            } ?? 11)
        }
    }
    private func receive(_ token: UInt64, requestID: UInt64) async throws -> (ncm_event, Data) {
        // Overall connect/readiness/media stages can contain multiple 15s protocol
        // steps. This bound is independent of the Rust per-stage deadlines.
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard handle == token else { throw NativeBackendError.closed }
            var event = ncm_event(); let status = ncm_backend_poll(token, &event, nil, 0)
            if status == 4 { try await Task.sleep(for: .milliseconds(10)); continue }
            if status == 3 { throw NativeBackendError.closed }
            var data = Data()
            if status == 5 {
                guard event.size > 0, event.size <= 64 * 1024 * 1024 else { throw NativeBackendError.malformedEvent }
                data = Data(count: event.size)
                let copied = data.withUnsafeMutableBytes { bytes in ncm_backend_poll(token, &event, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
                guard copied == 0 else { throw NativeBackendError.transport(code: copied) }
            } else if status != 0 { throw NativeBackendError.transport(code: status) }
            guard event.request_id == requestID, event.reserved == 0 else { throw NativeBackendError.malformedEvent }
            if event.kind == 10 { throw NativeBackendError.touchPreparationFailure(stage: event.stage, cause: event.cause) }
            if event.kind == 12 { throw NativeBackendError.applicationQueryFailure(stage: event.stage, cause: event.cause) }
            if event.kind == 3 { throw NativeBackendError.protocolFailure(stage: event.stage, cause: event.cause) }
            return (event, data)
        }
        throw NCMError.timeout
    }
    #if NCM_OFFLINE_FIXTURES
    /// Compiled only into the separately built host test target.
    func connectMediaFailureFixture() async throws {
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        var started: UInt64 = 0
        let code = ncm_test_start_media_failure(&started)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; try await finishConnect(started)
    }
    func connectVideoBurstFixture(_ sample: Data, continuous: Bool = true) async throws {
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        var started: UInt64 = 0
        let code = withSlices([sample]) { ncm_test_start_video_burst($0[0], continuous ? 1 : 0, &started) }
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; try await finishConnect(started)
    }
    func connectLoopbackFixture(port: UInt16) async throws {
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        var started: UInt64 = 0; let code = ncm_test_start_loopback(port, &started)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; try await finishConnect(started)
    }
    #endif
}
/// Strict host receipt checks; a successful control-channel handshake is not
/// automation readiness and cannot authorize a different process or UUID.
struct NCMXCTestAuthorization: Decodable {
    let authorized: Bool
    let processID: Int32
    let sessionIdentifier: UUID
    static func validate(_ data: Data, sessionID: UUID, processID: Int32) throws {
        guard !data.isEmpty, data.count <= 4096,
              let receipt = try? JSONDecoder().decode(Self.self, from: data),
              receipt.authorized, processID > 0, receipt.processID == processID,
              receipt.sessionIdentifier == sessionID else { throw NativeBackendError.malformedEvent }
    }
}

struct NCMXCTestScreenState: Equatable {
    let revision: UInt64, displayID: UInt64
    let orientation: Int64
    let scale: Double, boundsWidth: Double, boundsHeight: Double
    init(_ state: eiscue_automation_state) throws {
        guard state.phase == UInt32(EISCUE_AUTOMATION_READY), state.revision > 0,
              (1...4).contains(state.orientation), state.scale.isFinite, (0.5...8).contains(state.scale),
              state.bounds_width.isFinite, state.bounds_height.isFinite,
              state.bounds_width > 0, state.bounds_height > 0,
              state.bounds_width * state.scale <= 16384, state.bounds_height * state.scale <= 16384 else {
            throw NativeBackendError.touchPreparationFailure(stage: 38, cause: UInt32(EISCUE_AUTOMATION_GEOMETRY))
        }
        revision = state.revision; displayID = state.display_id; orientation = state.orientation
        scale = state.scale; boundsWidth = state.bounds_width; boundsHeight = state.bounds_height
    }
}

enum NCMXCTestImage {
    /// XCTest keeps native raster pixels and writes the display rotation into
    /// PNG orientation metadata. Tools need upright pixels, not a viewer-only
    /// rotation; normalize once before binding screenshot coordinates.
    static func uprightPNG(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (2...16384).contains(width), (2...16384).contains(height),
              width * height <= 32 * 1024 * 1024 else { throw NativeBackendError.malformedEvent }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard [1, 3, 6, 8].contains(orientation) else { throw NativeBackendError.malformedEvent }
        if orientation == 1 { return data }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary),
              image.width == (orientation == 3 ? width : height),
              image.height == (orientation == 3 ? height : width) else { throw NativeBackendError.malformedEvent }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw NativeBackendError.malformedEvent
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 64 * 1024 * 1024 else {
            throw NativeBackendError.malformedEvent
        }
        return output as Data
    }
}

struct NCMXCTestLayout: Equatable {
    let width: Int, height: Int
    let screen: NCMXCTestScreenState
    init(width: Int, height: Int, screen: NCMXCTestScreenState) throws {
        guard width > 1, height > 1, width <= 16384, height <= 16384,
              width * height <= 32 * 1024 * 1024 else { throw NativeBackendError.malformedEvent }
        let nativeWidth = screen.boundsWidth * screen.scale, nativeHeight = screen.boundsHeight * screen.scale
        let direct = abs(Double(width) - nativeWidth) <= 1 && abs(Double(height) - nativeHeight) <= 1
        let rotated = abs(Double(width) - nativeHeight) <= 1 && abs(Double(height) - nativeWidth) <= 1
        let landscape = screen.orientation == 3 || screen.orientation == 4
        guard (direct || rotated), landscape ? width >= height : height >= width else {
            throw NativeBackendError.coordinateSpaceChanged
        }
        self.width = width; self.height = height; self.screen = screen
    }
    init(png: Data, screen: NCMXCTestScreenState) throws {
        guard !png.isEmpty, png.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else { throw NativeBackendError.malformedEvent }
        try self.init(width: width, height: height, screen: screen)
    }
}

struct NCMXCTestGeometryTracker {
    private var lease: UInt64?
    private var layout: NCMXCTestLayout?
    private(set) var current: NativeVideoGeometry?
    mutating func reset() { lease = nil; layout = nil; current = nil }
    mutating func update(lease: UInt64, layout: NCMXCTestLayout) -> NativeVideoGeometry {
        if self.lease != lease || self.layout != layout || current == nil {
            self.lease = lease; self.layout = layout
            current = NativeVideoGeometry(id: UUID(), epoch: lease, revision: layout.screen.revision)
        }
        return current!
    }
}

private func withSlices<T>(_ data: [Data], _ index: Int = 0, _ slices: [ncm_bytes] = [], _ body: ([ncm_bytes]) -> T) -> T {
    if index == data.count { return body(slices) }
    return data[index].withUnsafeBytes { bytes in
        withSlices(data, index + 1, slices + [ncm_bytes(data: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)], body)
    }
}

/// Ordinary Lockdown only. Caller explicitly supplies the existing pairing plist.
/// Kept separate from the RP identity, discovery and screenshot/media API.
@MainActor public final class NativeLockdownSession {
    private var handle: UInt64 = 0
    private var ready = false
    private var busy = false
    public init() {}
    deinit { if handle != 0 { ncm_backend_close(handle) } }
    public func close() {
        let old = handle; handle = 0; ready = false
        if old != 0 { ncm_backend_close(old) }
    }
    public func connect(pairingRecord: Data, expectedUDID: String, authorized: Bool) async throws {
        try Task.checkCancellation()
        guard authorized else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard !pairingRecord.isEmpty, pairingRecord.count <= 1024 * 1024,
              !expectedUDID.isEmpty, expectedUDID.utf8.count <= 256 else { throw NativeBackendError.invalidIdentity }
        guard NativeDeveloperServices.linkedABIVersion == NCM_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        let row = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory()).row
        var started: UInt64 = 0
        let code = withSlices([pairingRecord, Data(expectedUDID.utf8)]) { slices in
            ncm_lockdown_start(row.index, UInt32(NCM_ALLOW_EXISTING_VERIFY), slices[0], slices[1], &started)
        }
        guard code == 0, started != 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; busy = true; defer { busy = false }
        do { try await receive(started, requestID: 0); ready = true }
        catch { close(); throw error }
    }
    /// Normal cleanup sends StopSession on the same TLS channel. Cancellation or
    /// background close instead revokes transport; it cannot confirm remote stop.
    public func stop() async throws {
        guard !busy else { throw NativeBackendError.busy }
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false; close() }
        let token = handle
        let code = ncm_backend_submit(token, 1, 5, 0, 0)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        try await receive(token, requestID: 1)
    }
    private func receive(_ token: UInt64, requestID: UInt64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard handle == token else { throw NativeBackendError.closed }
            var event = ncm_event()
            let status = ncm_backend_poll(token, &event, nil, 0)
            if status == 4 { try await Task.sleep(for: .milliseconds(10)); continue }
            guard status == 0 else { throw NativeBackendError.transport(code: status) }
            guard event.request_id == requestID, event.size == 0, event.reserved == 0 else { throw NativeBackendError.malformedEvent }
            if event.kind == 3 { throw NativeBackendError.protocolFailure(stage: event.stage, cause: event.cause) }
            guard event.kind == 2 else { throw NativeBackendError.malformedEvent }
            return
        }
        throw NCMError.timeout
    }
}

// Media decoding is intentionally off MainActor. Only complete, ordered HEVC
// access units cross the ABI; no compressed packet or decoded image is persisted.
import VideoToolbox
import CoreImage
import ImageIO

struct NCMVideoSample {
    let serial: UInt64, epoch: UInt64, ageMS: UInt64, revision: UInt64
    let timestamp: UInt32, sync: Bool, width: Int, height: Int
    let visibleSize: CGSize?
    let parameters: [Data]
    let bytes: Data
    init(_ data: Data) throws {
        guard data.count >= 64, data.count <= 8 * 1024 * 1024 else { throw NativeBackendError.malformedEvent }
        var offset = 0
        func number(_ count: Int) -> UInt64 {
            defer { offset += count }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        serial = number(8); epoch = number(8); ageMS = number(8); revision = number(8)
        timestamp = UInt32(number(4)); let flags = number(4)
        sync = flags & 1 != 0; width = Int(number(4)); height = Int(number(4))
        let lengths = (0..<4).map { _ in Int(number(4)) }
        let headerSize = flags & 2 != 0 ? 72 : 64
        guard data.count >= headerSize else { throw NativeBackendError.malformedEvent }
        if flags & 2 != 0 {
            let w = Int(number(4)), h = Int(number(4))
            guard w > 0, h > 0, w <= width, h <= height, width - w < 64, height - h < 64 else { throw NativeBackendError.malformedEvent }
            visibleSize = CGSize(width: w, height: h)
        } else { visibleSize = nil }
        guard flags <= 3, serial > 0, width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 32 * 1024 * 1024, lengths.allSatisfy({ $0 > 0 }),
              lengths.prefix(3).allSatisfy({ $0 <= 1024 * 1024 }),
              lengths.reduce(headerSize, +) == data.count else { throw NativeBackendError.malformedEvent }
        var fields: [Data] = []
        for length in lengths { fields.append(data.subdata(in: offset..<offset + length)); offset += length }
        parameters = Array(fields.prefix(3)); bytes = fields[3]
        // Validate length-prefixed NAL boundaries before CoreMedia sees bytes.
        var cursor = 0, count = 0
        while cursor < bytes.count {
            guard bytes.count - cursor >= 4 else { throw NativeBackendError.malformedEvent }
            let size = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[cursor + $1]) }
            cursor += 4; count += 1
            guard size >= 2, size <= bytes.count - cursor, count <= 256 else { throw NativeBackendError.malformedEvent }
            cursor += size
        }
    }
}

private final class NCMDecodedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var status: OSStatus = noErr
    func store(_ value: CVPixelBuffer?, status: OSStatus) { lock.lock(); defer { lock.unlock() }; buffer = value; self.status = status }
    func error() -> OSStatus { lock.lock(); defer { lock.unlock() }; return status }
    func take() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// Kept separate from the codec so geometry transitions can be tested without
/// compressed fixtures or a device. Access is confined to the decoder queue.
struct NCMVideoGeometryTracker {
    private struct Layout: Equatable {
        let epoch: UInt64, revision: UInt64
        let bufferWidth: Int, bufferHeight: Int
        let visibleRect: CGRect
    }
    private var layout: Layout?
    private(set) var current: NativeVideoGeometry?

    mutating func reset() { layout = nil; current = nil }

    mutating func update(epoch: UInt64, revision: UInt64, bufferWidth: Int, bufferHeight: Int,
                         visibleRect: CGRect) -> NativeVideoGeometry {
        let next = Layout(epoch: epoch, revision: revision, bufferWidth: bufferWidth,
                          bufferHeight: bufferHeight, visibleRect: visibleRect)
        if layout != next || current == nil {
            layout = next
            current = NativeVideoGeometry(id: UUID(), epoch: epoch, revision: revision)
        }
        return current!
    }
}

final class NCMVideoDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhoneAgent.ncm-video-decoder", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var revision: UInt64?, epoch: UInt64?
    private var geometry = NCMVideoGeometryTracker()
    #if DEBUG
    private var probeKeyframe: Data?
    func diagnosticKeyframe() async -> Data? {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.probeKeyframe) } }
    }
    #endif
    private var loggedGeometry: String?
    private var streamContentSize: CGSize?
    private var requiresSync = true
    private var latest: (buffer: CVPixelBuffer, rect: CGRect, received: ContinuousClock.Instant, serial: UInt64)?
    private var lastSerial: UInt64 = 0
    private var decodedCount: UInt64 = 0
    func diagnosticStatus() async -> String {
        await withCheckedContinuation { continuation in queue.async {
            let age = self.latest.map { String(describing: $0.received.duration(to: .now)) } ?? "none"
            continuation.resume(returning: "polled=\(self.lastSerial) decoded=\(self.decodedCount) latestAge=\(age) requiresSync=\(self.requiresSync)")
        } }
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
    func reset() async {
        await withCheckedContinuation { continuation in
            queue.async { self.resetOnQueue(); continuation.resume() }
        }
    }
    private func resetOnQueue() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; revision = nil; epoch = nil
        geometry.reset()
        latest = nil; streamContentSize = nil; loggedGeometry = nil; requiresSync = true
        #if DEBUG
        probeKeyframe = nil
        #endif
    }
    @discardableResult func consume(_ data: Data) async throws -> Bool {
        let observed = ContinuousClock.now
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                do { continuation.resume(returning: try self.decode(NCMVideoSample(data), observed: observed)) }
                catch { self.resetOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }
    private func decode(_ sample: NCMVideoSample, observed: ContinuousClock.Instant) throws -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard sample.serial > lastSerial else { throw NativeBackendError.malformedEvent }
        // The native mailbox can replace queued pictures with a keyframe. A gap
        // may hide a transient layout change, so never reuse its former token.
        if lastSerial > 0, sample.serial != lastSerial &+ 1 { geometry.reset() }
        lastSerial = sample.serial
        if revision != sample.revision || epoch != sample.epoch { resetOnQueue() }
        if requiresSync && !sample.sync { return false }
        if session == nil {
            guard sample.sync else { return false }
            var description: CMVideoFormatDescription?
            let p = sample.parameters
            let result = p[0].withUnsafeBytes { vps in p[1].withUnsafeBytes { sps in p[2].withUnsafeBytes { pps in
                let pointers = [vps.bindMemory(to: UInt8.self).baseAddress!, sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = p.map(\.count)
                return pointers.withUnsafeBufferPointer { pointers in sizes.withUnsafeBufferPointer { sizes in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4,
                        extensions: nil, formatDescriptionOut: &description)
                }}
            }}}
            guard result == noErr, let description else { throw NativeBackendError.screenshotFailure(stage: 20, cause: 1) }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let presented = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: false, useCleanAperture: true)
            guard (dimensions.width == sample.width && dimensions.height == sample.height) ||
                  (presented.width == CGFloat(sample.width) && presented.height == CGFloat(sample.height)) else { throw NativeBackendError.malformedEvent }
            var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { _, source, status, _, image, _, _ in
                if let source {
                    Unmanaged<NCMDecodedOutput>.fromOpaque(source).takeUnretainedValue().store(image, status: status)
                }
            }, decompressionOutputRefCon: nil)
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: &callback,
                decompressionSessionOut: &session)
            NSLog("NCM VT create status=%d", created)
            guard created == noErr else { throw NativeBackendError.screenshotFailure(stage: 20, cause: created == kVTInvalidSessionErr ? 13 : 14) }
            #if DEBUG
            if let session {
                var hardware: CFTypeRef?
                let queried = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: kCFAllocatorDefault, valueOut: &hardware)
                NSLog("NCM VT hardware query=%d value=%@", queried, String(describing: hardware))
            }
            #endif
            format = description; revision = sample.revision; epoch = sample.epoch
        }
        guard let session, let format else { throw NativeBackendError.malformedEvent }
        #if DEBUG
        if sample.sync {
            var annexB = Data()
            for parameter in sample.parameters { annexB.append(contentsOf: [0,0,0,1]); annexB.append(parameter) }
            let raw = [UInt8](sample.bytes); var offset = 0
            while offset < raw.count {
                let size = raw[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
                annexB.append(contentsOf: [0,0,0,1]); annexB.append(contentsOf: raw[offset..<offset+size]); offset += size
            }
            probeKeyframe = annexB
        }
        #endif
        let picture = try NCMDisplayPicture(sample.bytes, codedWidth: Int(CMVideoFormatDescriptionGetDimensions(format).width),
                                            codedHeight: Int(CMVideoFormatDescriptionGetDimensions(format).height))
        if let w = picture.visibleWidth, let h = picture.visibleHeight { streamContentSize = CGSize(width: w, height: h) }
        let pictureBytes = picture.bytes
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pictureBytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: pictureBytes.count,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw NativeBackendError.malformedEvent }
        let copied = pictureBytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pictureBytes.count) }
        guard copied == noErr else { throw NativeBackendError.malformedEvent }
        var buffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(sample.timestamp), timescale: 90000), decodeTimeStamp: .invalid)
        var size = pictureBytes.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr, let buffer else { throw NativeBackendError.malformedEvent }
        let output = NCMDecodedOutput()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [],
            frameRefcon: Unmanaged.passUnretained(output).toOpaque(), infoFlagsOut: nil)
        let waited = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr, waited == noErr, output.error() == noErr, let pixels = output.take() else {
            NSLog("NCM VT decode status=%d waited=%d callback=%d output=%d sync=%d", status, waited, output.error(), output.take() == nil ? 0 : 1, sample.sync ? 1 : 0)
            let invalid = [status, waited, output.error()].contains(kVTInvalidSessionErr)
            throw NativeBackendError.screenshotFailure(stage: 20, cause: invalid ? 13 : 14)
        }
        requiresSync = false
        decodedCount &+= 1
        // Include time in the Rust queue when deciding whether capture advanced after the request.
        let rect: CGRect
        if let size = streamContentSize ?? sample.visibleSize {
            rect = CGRect(x: 0, y: CGFloat(CVPixelBufferGetHeight(pixels)) - size.height, width: size.width, height: size.height)
            guard CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)).contains(rect) else { throw NativeBackendError.malformedEvent }
        } else {
        rect = try NCMVideoImage.visibleRect(buffer: pixels, width: streamContentSize.map { Int($0.width) } ?? sample.width, height: streamContentSize.map { Int($0.height) } ?? sample.height,
            formatAperture: CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true))
        }
        let encoded = CMVideoFormatDescriptionGetDimensions(format)
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: false, useCleanAperture: true)
        let geometry = "SPS=\(sample.width)x\(sample.height) coded=\(encoded.width)x\(encoded.height) presentation=\(presentation) buffer=\(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels)) stride=\(CVPixelBufferGetBytesPerRow(pixels)) clean=\(CVImageBufferGetCleanRect(pixels)) preferred=\(String(describing: NCMVideoImage.preferredRect(buffer: pixels))) displayContent=\(String(describing: sample.visibleSize)) trailerContent=\(String(describing: streamContentSize)) selected=\(rect)"
        if loggedGeometry != geometry {
            NSLog("NCM video geometry %@", geometry)
            loggedGeometry = geometry
        }
        latest = (pixels, rect, observed.advanced(by: .milliseconds(-Int64(min(sample.ageMS, UInt64(Int64.max))))), sample.serial)
        _ = self.geometry.update(epoch: sample.epoch, revision: sample.revision,
                                 bufferWidth: CVPixelBufferGetWidth(pixels), bufferHeight: CVPixelBufferGetHeight(pixels),
                                 visibleRect: rect)
        return true
    }
    func jpeg(notBefore: ContinuousClock.Instant, confirmedEpoch: UInt64? = nil, confirmedSerial: UInt64 = 0) async throws -> Data? {
        try await jpegWithGeometry(notBefore: notBefore, confirmedEpoch: confirmedEpoch, confirmedSerial: confirmedSerial)?.data
    }
    func currentGeometry() async -> (geometry: NativeVideoGeometry, serial: UInt64)? {
        await withCheckedContinuation { continuation in queue.async {
            guard let geometry = self.geometry.current, let latest = self.latest, !self.requiresSync else {
                continuation.resume(returning: nil); return
            }
            continuation.resume(returning: (geometry, latest.serial))
        } }
    }
    func jpegWithGeometry(notBefore: ContinuousClock.Instant, confirmedEpoch: UInt64? = nil, confirmedSerial: UInt64 = 0) async throws -> NativeVideoSnapshot? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NativeVideoSnapshot?, Error>) in
            queue.async {
                do {
                    guard let latest = self.latest, let geometry = self.geometry.current, !self.requiresSync,
                          latest.received >= notBefore || (confirmedSerial > 0 && self.epoch == confirmedEpoch && latest.serial >= confirmedSerial)
                    else { continuation.resume(returning: nil); return }
                    let data = try NCMVideoImage.jpeg(buffer: latest.buffer, rect: latest.rect, context: self.context)
                    continuation.resume(returning: NativeVideoSnapshot(data: data, geometry: geometry))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Transport/assembly diagnostics; no arbitrary maximum picture age.
struct NCMVideoSnapshotFailure {
    static func timeoutCause(datagrams: UInt64, rtp: UInt64, frames: UInt64, overflows: UInt64, initialOverflows: UInt64 = 0) -> UInt32 {
        if datagrams == 0 { return 8 }
        if rtp == 0 { return 9 }
        if frames == 0 { return 10 }
        if overflows > initialOverflows { return 12 }
        return 11
    }
}

/// SW:1 screen-sharing trailers observed on the real stream. Flag 2 carries
/// a BE16 contents rectangle; flag 3 additionally carries the encoded size.
/// Parse RBSP after emulation-prevention removal: escaping spans the boundary
/// between coded slice and metadata, so the footer has no fixed EBSP length.
struct NCMDisplayPicture {
    let bytes: Data
    let visibleWidth: Int?
    let visibleHeight: Int?
    init(_ data: Data, codedWidth: Int, codedHeight: Int) throws {
        let input = [UInt8](data)
        var output = Data(), offset = 0
        var visible: (Int, Int)?
        while offset < input.count {
            guard input.count - offset >= 4 else { throw NativeBackendError.malformedEvent }
            let length = input[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length >= 2, length <= input.count - offset else { throw NativeBackendError.malformedEvent }
            var nal = Array(input[offset..<offset+length]); offset += length
            let type = (nal[0] >> 1) & 63
            if type < 32 {
                let raw = Self.unescape(Array(nal.dropFirst(2)))
                let tailLength = raw.last == 2 ? 9 : raw.last == 3 ? 13 : 0
                if tailLength > 0, raw.count > tailLength {
                    let t = Array(raw.suffix(tailLength))
                    func pair(_ i: Int) -> Int { Int(t[i]) << 8 | Int(t[i+1]) }
                    let base = tailLength == 13 ? 4 : 0
                    let canvasMatches = base == 0 || (pair(0) == codedWidth && pair(2) == codedHeight)
                    let w = pair(base+4), h = pair(base+6)
                    if canvasMatches, pair(base) == 0, pair(base+2) == 0,
                       w > 0, h > 0, w <= codedWidth, h <= codedHeight,
                       codedWidth - w < 64, codedHeight - h < 64 {
                        if let visible, visible.0 != w || visible.1 != h { throw NativeBackendError.malformedEvent }
                        visible = (w, h)
                        nal = Array(nal.prefix(2)) + Self.escape(Array(raw.dropLast(tailLength)))
                    }
                }
            }
            let n = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: n) { output.append(contentsOf: $0) }
            output.append(contentsOf: nal)
        }
        bytes = output; visibleWidth = visible?.0; visibleHeight = visible?.1
    }
    private static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [], zeros = 0
        for (index, byte) in bytes.enumerated() {
            if zeros == 2, byte == 3, index+1 < bytes.count, bytes[index+1] <= 3 {
                zeros = 0; continue
            }
            result.append(byte); zeros = byte == 0 ? min(2,zeros+1) : 0
        }
        return result
    }
    private static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [], zeros = 0
        for byte in bytes {
            if zeros == 2, byte <= 3 { result.append(3); zeros = 0 }
            result.append(byte); zeros = byte == 0 ? zeros+1 : 0
        }
        return result
    }

}

/// Crop only declared picture geometry; never infer edges from UI colors.
enum NCMVideoImage {
    static func visibleRect(buffer: CVPixelBuffer, width: Int, height: Int, formatAperture: CGRect? = nil) throws -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let size = CGSize(width: width, height: height)
        guard width > 0, height > 0, bounds.width >= size.width, bounds.height >= size.height else { throw NativeBackendError.malformedEvent }
        func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isInfinite && !rect.isEmpty && bounds.contains(rect) &&
            rect == rect.integral && rect.width <= size.width && rect.height <= size.height
        }
        // iOS 26+ producers may provide a more precise display region than the
        // ordinary clean aperture. CoreImage's automatic aperture option also
        // gives this attachment priority; preserve its offsets in raw coordinates.
        if let preferred = preferredRect(buffer: buffer), valid(preferred) { return preferred }
        // CoreVideo clean-rectangle coordinates already use CoreImage's lower-left origin.
        let clean = CVImageBufferGetCleanRect(buffer)
        if clean != bounds, valid(clean) { return clean }
        if let aperture = formatAperture {
            let rect = CGRect(x: aperture.minX, y: bounds.height - aperture.maxY, width: aperture.width, height: aperture.height)
            if valid(rect) { return rect }
        }
        // Hardware decoders may allocate aligned buffers with padding at right/bottom.
        return CGRect(x: 0, y: bounds.height - size.height, width: size.width, height: size.height)
    }
    static func preferredRect(buffer: CVPixelBuffer) -> CGRect? {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferPreferredCleanApertureKey, nil),
              let aperture = value as? [String: Any],
              let width = aperture[kCVImageBufferCleanApertureWidthKey as String] as? NSNumber,
              let height = aperture[kCVImageBufferCleanApertureHeightKey as String] as? NSNumber else { return nil }
        let x = (aperture[kCVImageBufferCleanApertureHorizontalOffsetKey as String] as? NSNumber)?.doubleValue ?? 0
        let y = (aperture[kCVImageBufferCleanApertureVerticalOffsetKey as String] as? NSNumber)?.doubleValue ?? 0
        return CGRect(x: (Double(CVPixelBufferGetWidth(buffer)) - width.doubleValue) / 2 + x,
                      y: (Double(CVPixelBufferGetHeight(buffer)) - height.doubleValue) / 2 - y,
                      width: width.doubleValue, height: height.doubleValue)
    }
    static func jpeg(buffer: CVPixelBuffer, rect: CGRect, context: CIContext) throws -> Data {
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: rect)
        guard let cg = context.createCGImage(image, from: rect) else { throw NativeBackendError.screenshotFailure(stage: 20, cause: 1) }
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw NativeBackendError.malformedEvent }
        CGImageDestinationAddImage(target, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw NativeBackendError.screenshotFailure(stage: 20, cause: 1) }
        return data as Data
    }
}
