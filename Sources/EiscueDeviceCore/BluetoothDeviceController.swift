import Foundation

#if DEBUG
enum BluetoothStationaryRelativeComparison {
    static let anchor = BluetoothRelativeCalibrationProbe.horizontalSmall.anchor
    static let stroke = BluetoothRelativeStroke(totalDX: 0, totalDY: 0, steps: 12, durationMS: 192)
}
#endif

#if os(iOS)
import UIKit

/// BLE input and user-authorized ReplayKit observation. The host presents the
/// system broadcast picker and an owned calibration surface before enabling AI.
@MainActor
public final class BluetoothDeviceController: DeviceActuator, HIDRouteSetup {
    public let board: BluetoothBoardClient
    public var onChange: (@MainActor () -> Void)?
    public var onHardwareStop: (@MainActor (BluetoothHardwareStopEvent) -> Void)?
    public var supportsCompanionDisplay: Bool { board.supportsCompanionDisplay }
    public var isHardwareStopLatched: Bool { board.isHardwareStopLatched }
    public private(set) var isConnected = false
    public private(set) var isCalibrating = false
    public private(set) var inputRoute: BluetoothBoardInputRoute = .bluetooth
    public private(set) var outputInfo: BluetoothBoardOutputInfo?
    private var store: ScreenBroadcastStore?
    var calibration: Calibration?
    private var calibrationFrame: ObservedFrame?
    private var calibrationObservation: (frame: ObservedFrame, issuedUptime: TimeInterval)?
    private weak var calibrationWindow: UIWindow?
    private weak var calibrationView: UIView?
    private var calibrationViewport: Viewport?
    private let operations = BluetoothOperationGate()
    private var releaseToken: UUID?
    private var epoch = UUID()
    private var keyboardAvailable = false
    private var keyboardVerified = false
    private var absoluteAvailable = false
    public private(set) var supportsRelativeDrag = false
    public private(set) var isRelativeDragReady = false
    var relativeCalibration: BluetoothRelativeDragCalibration?
    private var relativeProbeReceipts: [BluetoothRelativeCalibrationProbe: BluetoothRelativeCalibrationReceipt] = [:]
    private var navigationAvailable = false
    private var probeFailure: DeviceControlError?
    private var geometryRevision = UUID()
    private var observedGeometry: (session: UUID, orientation: ScreenBroadcastOrientation, width: Int, height: Int)?
    private var lastDispatchedUptime: TimeInterval = -.infinity
    private var cachedScreenState: ScreenBroadcastState?
    private var cachedScreenUptime: TimeInterval = -.infinity
    private var screenReadToken = UUID()

    public init(board: BluetoothBoardClient = BluetoothBoardClient(), screenStore: ScreenBroadcastStore? = nil) {
        self.board = board; store = screenStore
        board.onStateChange = { [weak self] state in
            guard let self else { return }
            if state != .ready {
                if isConnected || isCalibrating { epoch = UUID() }
                isConnected = false; clearCalibration()
                outputInfo = nil; navigationAvailable = false
                supportsRelativeDrag = false; isRelativeDragReady = false
            }
            onChange?()
        }
        board.onHardwareStop = { [weak self] event in
            guard let self else { return }
            // Invalidate every observation before notifying the host. A stop
            // cannot leave an old coordinate or calibration authorized.
            epoch = UUID(); clearCalibration()
            onChange?(); onHardwareStop?(event)
        }
    }

    public func updateCompanionStatus(_ status: BluetoothCompanionStatus) { board.updateCompanionStatus(status) }

    public var screenState: ScreenBroadcastState? {
        guard UIApplication.shared.isProtectedDataAvailable else { return nil }
        guard let cachedScreenState else { return nil }
        guard cachedScreenState.isActive,
              ProcessInfo.processInfo.systemUptime - cachedScreenUptime > ScreenBroadcastStore.maximumFrameAge else { return cachedScreenState }
        return ScreenBroadcastState(phase: .stale, sessionID: cachedScreenState.sessionID,
            updatedAt: cachedScreenState.updatedAt, frameID: cachedScreenState.frameID,
            orientation: cachedScreenState.orientation, width: cachedScreenState.width, height: cachedScreenState.height)
    }
    public var isInputReady: Bool { isConnected && !isHardwareStopLatched && absoluteAvailable && keyboardAvailable }
    public var isPointerVerified: Bool {
        guard !isHardwareStopLatched, !isCalibrating, let calibration else { return false }
        return calibration.matches(screenState)
    }
    public var isRelativeDragVerified: Bool { isPointerVerified && isRelativeDragReady && relativeCalibration != nil }

    public func cachedStatus() async -> DeviceStatus {
        guard !isHardwareStopLatched else { return .unavailable(reason: BluetoothBoardError.hardwareStopped.localizedDescription) }
        guard isConnected else { return .unavailable(reason: message("bluetooth.connect")) }
        if let probeFailure { return .unavailable(reason: probeFailure.localizedDescription) }
        guard isInputReady else { return .unavailable(reason: message(inputRoute == .usb ? "bluetooth.usbMissing" : "bluetooth.hidMissing")) }
        guard screenState?.isActive == true else { return .unavailable(reason: message("bluetooth.share")) }
        guard isPointerVerified else { return .unavailable(reason: message("bluetooth.calibrate")) }
        var capabilities: Set<DeviceCapability> = [.screenshot, .tap]
        if isRelativeDragVerified { capabilities.insert(.swipe) }
        if keyboardAvailable && keyboardVerified {
            capabilities.insert(.textInput)
            if navigationAvailable { capabilities.insert(.keyboardNavigation) }
        }
        return .ready(capabilities: capabilities)
    }

    public func probe() async -> DeviceStatus {
        await refreshScreenState()
        guard isConnected, releaseToken == nil, !isCalibrating, operations.beginStatus() else { return await cachedStatus() }
        defer { operations.endStatus() }
        let token = epoch
        do {
            let receipt = try await board.command(opcode: 7)
            try requireEpoch(token)
            absoluteAvailable = receipt.emittedReports & 1 != 0
            keyboardAvailable = receipt.emittedReports & 2 != 0
            updateRelativeReadiness(receipt.emittedReports)
            if outputInfo != nil {
                let info = try await readOutputInfo(token: token)
                guard info.selectedRoute == inputRoute else { throw DeviceControlError.serviceUnavailable(.input) }
                navigationAvailable = info.supportsNavigation
            }
            guard absoluteAvailable && keyboardAvailable else { throw DeviceControlError.serviceUnavailable(.input) }
            probeFailure = nil
        } catch {
            probeFailure = Self.convert(error); clearCalibration(); onChange?()
        }
        return await cachedStatus()
    }

    /// Change only after release/disconnect. Reconnecting requires a fresh
    /// pointer/text check even if the next route uses the same physical board.
    public func selectInputRoute(_ route: BluetoothBoardInputRoute) throws {
        guard !operations.isBusy, releaseToken == nil, !isConnected, board.state != .ready else { throw DeviceControlError.busy }
        epoch = UUID(); clearCalibration()
        inputRoute = route; outputInfo = nil; navigationAvailable = false
        onChange?()
    }

    public func connectBluetoothBoard() async throws {
        guard !operations.isBusy, releaseToken == nil else { throw DeviceControlError.busy }
        try operations.beginExclusive(); defer { operations.endAction() }
        epoch = UUID(); clearCalibration(); probeFailure = nil
        let token = epoch
        do {
            try await board.connect()
            try requireConnectionEpoch(token)
            let first = try await board.command(opcode: 7, pairingHandshake: true)
            try requireConnectionEpoch(token)
            let selectable = first.emittedReports & BluetoothBoardProtocol.outputSelectionFlag != 0
            if selectable {
                let info = try await readOutputInfo(token: token)
                guard inputRoute != .usb || info.supportsUSB else { throw DeviceControlError.connection(message("bluetooth.usbRequired")) }
                _ = try await board.command(opcode: 8, payload: [inputRoute.commandValue])
                try requireConnectionEpoch(token)
                let selected = try await readOutputInfo(token: token)
                guard selected.selectedRoute == inputRoute else { throw DeviceControlError.connection(message("bluetooth.outputMismatch")) }
            } else if inputRoute == .usb {
                throw DeviceControlError.connection(message("bluetooth.usbRequired"))
            }
            let deadline = Date().addingTimeInterval(40)
            while true {
                try Task.checkCancellation()
                let receipt = try await board.command(opcode: 7)
                try requireConnectionEpoch(token)
                absoluteAvailable = receipt.emittedReports & 1 != 0
                keyboardAvailable = receipt.emittedReports & 2 != 0
                updateRelativeReadiness(receipt.emittedReports)
                if selectable {
                    let info = try await readOutputInfo(token: token)
                    guard info.selectedRoute == inputRoute else { throw DeviceControlError.connection(message("bluetooth.outputMismatch")) }
                    navigationAvailable = info.supportsNavigation
                }
                if absoluteAvailable && keyboardAvailable { break }
                guard Date() < deadline else {
                    throw DeviceControlError.connection(message(inputRoute == .usb ? "bluetooth.usbMissing" : "bluetooth.hidMissing"))
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            try requireConnectionEpoch(token)
            isConnected = true; onChange?()
        } catch {
            if epoch == token { board.disconnect(); isConnected = false }
            throw (error as? BluetoothBoardError)?.connectionSetupError ?? Self.convert(error)
        }
    }

    public func disconnect() async -> ReleaseConfirmation {
        epoch = UUID(); clearCalibration(); isConnected = false
        let token = UUID(); releaseToken = token
        defer { if releaseToken == token { releaseToken = nil }; onChange?() }
        // Cleanup must survive cancellation of the user task that triggered it.
        let client = board
        await Task { @MainActor in
            if client.state == .ready { _ = try? await client.stop() }
            client.disconnect()
        }.value
        try? store?.requestStop()
        await refreshScreenState()
        return .unconfirmed
    }

    public func stopSharing() async throws {
        guard !operations.isBusy, releaseToken == nil else { throw DeviceControlError.busy }
        epoch = UUID(); clearCalibration()
        let token = UUID(); releaseToken = token
        defer { if releaseToken == token { releaseToken = nil }; onChange?() }
        await releaseHeldInput()
        try screenStore().requestStop()
        await refreshScreenState()
    }

    public func capture() async throws -> DeviceScreenshot {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        try await beginAction(allowCalibration: true); defer { operations.endAction() }
        // Host progress can change its own UI between actions. Observe after
        // this request too, rather than returning a pre-update cached frame.
        let observation = try await freshFrame(after: max(lastDispatchedUptime, requestedAt), token: epoch)
        calibrationObservation = (observation, ProcessInfo.processInfo.systemUptime)
        let image = observation.screenshot
        return DeviceScreenshot(frameID: image.frameID, capturedAt: image.capturedAt, width: image.width,
            height: image.height, mimeType: image.mimeType, data: image.data, geometry: geometry(observation))
    }

    public func releaseInput() async throws {
        guard !operations.isBusy, releaseToken == nil else { throw DeviceControlError.busy }
        calibrationObservation = nil
        guard isConnected else { return }
        try operations.beginExclusive(); defer { operations.endAction() }
        try await BluetoothTaskInputRelease.run(release: {
            _ = try await self.board.stop()
            self.lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
        }, calibrationMatches: {
            guard let calibration = self.calibration else { return nil }
            guard let current = try? await self.observeOffMain() else { return false }
            return calibration.matches(current)
        }, invalidateCalibration: { self.clearCalibration(); self.onChange?() })
    }

    public func frameState() async throws -> DeviceFrameState {
        guard isConnected, probeFailure == nil else { throw DeviceControlError.notConnected }
        let current = try await observeOffMain()
        return DeviceFrameState(geometry: geometry(current), isLive: true, confirmedUptime: current.observedUptime)
    }

    public func perform(_ action: DeviceAction, frame: FrameGrant) async throws -> SubmissionResult {
        // Prove all route-specific admission failures before entering input.
        var relativeStroke: BluetoothRelativeStroke?
        do {
            try requireEpoch(epoch)
            guard !operations.isBusy, releaseToken == nil, !isCalibrating else { throw DeviceControlError.busy }
            let current = try await observeOffMain()
            guard let calibration, calibration.matches(current),
                  try await frameState().geometry == frame.geometry else { throw DeviceControlError.staleFrame }
            for point in action.points { _ = try calibration.hidPoint(point, in: current.screenshot) }
            if case .swipe(let from, let to, let duration) = action {
                guard isRelativeDragReady, let relativeCalibration else { throw DeviceControlError.capabilityUnavailable(.swipe) }
                relativeStroke = try relativeCalibration.plan(displacement: DevicePoint(
                    x: (to.x - from.x) / Double(current.screenshot.width),
                    y: (to.y - from.y) / Double(current.screenshot.height)), duration: duration,
                    start: DevicePoint(x: from.x / Double(current.screenshot.width), y: from.y / Double(current.screenshot.height)))
            }
            guard action.capability != .home && action.capability != .launchApplication else {
                throw DeviceControlError.capabilityUnavailable(action.capability)
            }
            if action.capability == .textInput || action.capability == .keyboardNavigation {
                guard keyboardAvailable && keyboardVerified else { throw DeviceControlError.capabilityUnavailable(action.capability) }
                if action.capability == .keyboardNavigation, !navigationAvailable { throw DeviceControlError.capabilityUnavailable(.keyboardNavigation) }
            }
        } catch { return .notSubmitted(Self.convert(error)) }
        do {
            switch action {
            case .tap(let p): try await tap(at: p, frame: frame)
            case .swipe(let from, _, _):
                guard let relativeStroke else { return .notSubmitted(.capabilityUnavailable(.swipe)) }
                try await swipe(from: from, stroke: relativeStroke, frame: frame)
            case .typeText(let text): try await paste(text, frameID: frame.frameID, validation: false, grant: frame)
            case .pressKey(let key): try await pressKey(key, frame: frame)
            case .home, .launch: return .notSubmitted(.capabilityUnavailable(action.capability))
            }
            return .submitted
        } catch { throw Self.convert(error) }
    }

    public func listApplications() async throws -> [DeviceApplication] { throw DeviceControlError.capabilityUnavailable(.listApplications) }

    private func geometry(_ frame: ObservedFrame) -> DeviceFrameGeometry {
        let value = (session: frame.sessionID, orientation: frame.orientation, width: frame.screenshot.width, height: frame.screenshot.height)
        if let old = observedGeometry,
           old.session != value.session || old.orientation != value.orientation || old.width != value.width || old.height != value.height {
            geometryRevision = UUID()
        }
        observedGeometry = value
        return DeviceFrameGeometry(sessionID: epoch, revision: geometryRevision.uuidString, width: value.width, height: value.height)
    }
    private func mapping(for grant: FrameGrant) async throws -> (ObservedFrame, Calibration) {
        let current = try await observeOffMain()
        guard let calibration, calibration.matches(current), geometry(current) == grant.geometry else { throw DeviceControlError.staleFrame }
        return (current, calibration)
    }
    private static func convert(_ error: Error) -> DeviceControlError {
        if let error = error as? DeviceControlError { return error }
        if let error = error as? BluetoothBoardError { return error.deviceControlError }
        return .connectionLost
    }

    private func tap(at point: DevicePoint, frame: FrameGrant) async throws {
        try await beginAction(); defer { operations.endAction() }
        let (frame, mapping) = try await mapping(for: frame)
        let position = try mapping.hidPoint(point, in: frame.screenshot)
        let token = epoch
        try await repositionRelativePointer(position, mapping: mapping, token: token)
        try await requireCurrent(mapping, token: token)
        try await absolute(position, pressed: true)
        try await release(position, token: token)
    }

    private func swipe(from: DevicePoint, stroke: BluetoothRelativeStroke, frame: FrameGrant) async throws {
        try await beginAction(); defer { operations.endAction() }
        let (frame, mapping) = try await mapping(for: frame)
        let start = try mapping.hidPoint(from, in: frame.screenshot)
        let token = epoch
        do {
            try await repositionRelativePointer(start, mapping: mapping, token: token)
            try await Task.sleep(for: .milliseconds(180))
            try await requireCurrent(mapping, token: token)
            try await sendRelativeStroke(stroke, token: token)
            try await requireCurrent(mapping, token: token)
        } catch {
            await releaseHeldInput()
            // A partial drag may have changed the screen. Never repeat it.
            throw DeviceControlError.deliveryUnknown(message("bluetooth.interrupted"))
        }
    }

    /// Only available while the host's bound calibration target is visible.
    /// The host must observe the actual field value before markKeyboardVerified.
    public func pasteCalibrationText(_ text: String, frameID: UUID) async throws {
        try await paste(text, frameID: frameID, validation: true)
    }

    private func paste(_ text: String, frameID: UUID, validation: Bool, grant: FrameGrant? = nil) async throws {
        try DeviceInputValidation.text(text)
        try await beginAction(allowCalibration: validation); defer { operations.endAction() }
        let mapping: Calibration
        if let grant { (_, mapping) = try await self.mapping(for: grant) }
        else { (_, mapping) = try await consumeCalibrationObservation(frameID) }
        guard keyboardAvailable, validation ? isCalibrating : keyboardVerified else { throw DeviceControlError.capabilityUnavailable(.textInput) }
        if validation { try await checkCalibrationGeometry() }
        // Reading the pasteboard back fails while Eiscue is in the background,
        // which is the normal state during a cross-app task. A changed count
        // proves this write landed without reading any pasteboard content.
        let before = UIPasteboard.general.changeCount
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        guard UIPasteboard.general.changeCount != before else { throw DeviceControlError.connection(message("bluetooth.clipboard")) }
        try await requireCurrent(mapping, token: epoch)
        lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
        defer { lastDispatchedUptime = ProcessInfo.processInfo.systemUptime }
        _ = try await board.command(opcode: 6, payload: [0x08, 0x19])
    }

    private func pressKey(_ key: DeviceKeyboardAction, frame: FrameGrant) async throws {
        try await beginAction(); defer { operations.endAction() }
        let (_, mapping) = try await mapping(for: frame)
        guard keyboardAvailable, keyboardVerified, navigationAvailable else { throw DeviceControlError.capabilityUnavailable(.keyboardNavigation) }
        let token = epoch
        try await requireCurrent(mapping, token: token)
        switch key {
        case .search: try await sendKey(opcode: 6, payload: [0x08, 0x2C], token: token)
        case .enter: try await sendKey(opcode: 4, payload: [1], token: token)
        case .escape: try await sendKey(opcode: 4, payload: [5], token: token)
        }
    }

    private func sendKey(opcode: UInt8, payload: [UInt8], token: UUID) async throws {
        try requireEpoch(token)
        lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
        defer { lastDispatchedUptime = ProcessInfo.processInfo.systemUptime }
        _ = try await board.command(opcode: opcode, payload: payload)
        // A shortcut can leave the app. Cancellation or disconnect after its
        // acknowledged send must not make a second send look safe.
        do { try requireEpoch(token) }
        catch { throw DeviceControlError.deliveryUnknown(message("bluetooth.interrupted")) }
    }

    private func readOutputInfo(token: UUID) async throws -> BluetoothBoardOutputInfo {
        let receipt = try await board.command(opcode: 9)
        try requireConnectionEpoch(token)
        let info = try BluetoothBoardOutputInfo(bits: receipt.emittedReports)
        guard !(info.isS3 || info.supportsUSB) || board.usesAuthenticatedCommands else {
            throw BluetoothBoardError.authenticationFailed
        }
        outputInfo = info; onChange?()
        return info
    }

    /// Called only while the host's full-screen, non-destructive calibration
    /// target is visible. Raw points are normalized HID coordinates, not pixels.
    public func beginCalibration(window: UIWindow, viewport: UIView) async throws {
        try await beginAction(); defer { operations.endAction() }
        guard absoluteAvailable else { throw DeviceControlError.notConnected }
        clearCalibration()
        let token = epoch, binding = try Viewport(window: window, view: viewport)
        let frame = try await freshFrame(after: ProcessInfo.processInfo.systemUptime, token: token)
        guard try Viewport(window: window, view: viewport) == binding,
              binding.matches(frame) else { throw DeviceControlError.connection(message("bluetooth.fullScreenRequired")) }
        calibrationWindow = window; calibrationView = viewport; calibrationViewport = binding
        calibrationFrame = frame; isCalibrating = true
        onChange?()
    }

    public func calibrationClick(x: Double, y: Double) async throws {
        guard isCalibrating, !operations.isBusy, releaseToken == nil, (0.1...0.9).contains(x), (0.1...0.9).contains(y) else { throw DeviceControlError.invalidCoordinates }
        try operations.beginExclusive(); defer { operations.endAction() }
        let token = epoch, p = DevicePoint(x: x, y: y)
        try await checkCalibrationGeometry()
        try await repositionRelativePointer(p, mapping: nil, token: token)
        try await Task.sleep(for: .milliseconds(180))
        try requireEpoch(token)
        try await checkCalibrationGeometry()
        try await absolute(p, pressed: true)
        try await release(p, token: token)
    }

    /// Three corner samples fit an affine mapping, the fourth independently
    /// verifies it. Samples are normalized points observed by UIKit, not ACKs.
    public func completeCalibration(observed: [DevicePoint]) async throws {
        guard isCalibrating, !operations.isBusy, releaseToken == nil, observed.count == 4 else { throw DeviceControlError.invalidCoordinates }
        try operations.beginExclusive(); defer { operations.endAction() }
        try await checkCalibrationGeometry()
        guard let original = calibrationFrame else { throw DeviceControlError.staleFrame }
        calibration = try Calibration(observed: observed, frame: original)
        onChange?()
    }

    /// Repositions without a pressed button, then emits one fixed relative drag.
    /// The returned token binds the host's UIKit trace to this calibration visit.
    public func runRelativeCalibrationProbe(_ probe: BluetoothRelativeCalibrationProbe) async throws -> UUID {
        guard isCalibrating, calibration != nil, !operations.isBusy, releaseToken == nil else { throw DeviceControlError.busy }
        guard supportsRelativeDrag, isRelativeDragReady else { throw DeviceControlError.capabilityUnavailable(.swipe) }
        try operations.beginExclusive(); defer { operations.endAction() }
        try await checkCalibrationGeometry()
        guard let calibration, let frame = calibrationFrame else { throw DeviceControlError.staleFrame }
        let anchor = try calibration.hidPoint(DevicePoint(x: probe.anchor.x * Double(frame.screenshot.width),
            y: probe.anchor.y * Double(frame.screenshot.height)), in: frame.screenshot)
        let token = epoch
        relativeCalibration = nil; relativeProbeReceipts[probe] = nil
        do {
            try await repositionRelativePointer(anchor, mapping: calibration, token: token)
            try await Task.sleep(for: .milliseconds(180))
            try requireEpoch(token)
            try await checkCalibrationGeometry()
            let dispatchUptime = ProcessInfo.processInfo.systemUptime
            try await sendRelativeStroke(probe.stroke, token: token)
            let completedUptime = ProcessInfo.processInfo.systemUptime
            try await checkCalibrationGeometry()
            let receipt = UUID()
            relativeProbeReceipts[probe] = BluetoothRelativeCalibrationReceipt(token: receipt,
                dispatchUptime: dispatchUptime, completedUptime: completedUptime)
            return receipt
        } catch {
            await releaseHeldInput()
            if (error as? DeviceControlError)?.isDeliveryUnknown != true {
                throw DeviceControlError.deliveryUnknown(message("bluetooth.interrupted"))
            }
            throw error
        }
    }

    #if DEBUG
    /// A fixed diagnostic hold on the owned calibration page. No calibration receipt or grant is issued.
    public func debugRunStationaryRelativeComparison(requireHost: @MainActor () throws -> Void) async throws
        -> (dispatchUptime: TimeInterval, completedUptime: TimeInterval) {
        try requireHost()
        guard isCalibrating, calibration != nil, !operations.isBusy, releaseToken == nil else { throw DeviceControlError.busy }
        guard supportsRelativeDrag, isRelativeDragReady else { throw DeviceControlError.capabilityUnavailable(.swipe) }
        try operations.beginExclusive(); defer { operations.endAction() }
        try await checkCalibrationGeometry()
        try requireHost()
        guard let calibration, let frame = calibrationFrame else { throw DeviceControlError.staleFrame }
        let point = BluetoothStationaryRelativeComparison.anchor
        let anchor = try calibration.hidPoint(DevicePoint(x: point.x * Double(frame.screenshot.width),
            y: point.y * Double(frame.screenshot.height)), in: frame.screenshot)
        let token = epoch
        do {
            // Match the normal unpressed reposition, with host checks after each wait.
            let nudge = DevicePoint(x: anchor.x <= 0.985 ? anchor.x + 0.015 : anchor.x - 0.015, y: anchor.y)
            try await absolute(nudge, pressed: false)
            try await Task.sleep(for: .milliseconds(32))
            try requireHost()
            try await requireCurrent(calibration, token: token)
            try requireHost()
            try await absolute(anchor, pressed: false)
            try await Task.sleep(for: .milliseconds(180))
            try requireHost()
            try requireEpoch(token)
            try await checkCalibrationGeometry()
            try requireHost()
            let dispatchUptime = ProcessInfo.processInfo.systemUptime
            try await sendRelativeStroke(BluetoothStationaryRelativeComparison.stroke, token: token)
            let completedUptime = ProcessInfo.processInfo.systemUptime
            try await checkCalibrationGeometry()
            try requireHost()
            return (dispatchUptime, completedUptime)
        } catch {
            await releaseHeldInput()
            if (error as? DeviceControlError)?.isDeliveryUnknown != true {
                throw DeviceControlError.deliveryUnknown(message("bluetooth.interrupted"))
            }
            throw error
        }
    }
    #endif

    public func completeRelativeCalibration(observed: [BluetoothRelativeCalibrationObservation]) async throws {
        guard isCalibrating, calibration != nil, !operations.isBusy, releaseToken == nil else { throw DeviceControlError.busy }
        guard supportsRelativeDrag, isRelativeDragReady else { throw DeviceControlError.capabilityUnavailable(.swipe) }
        try operations.beginExclusive(); defer { operations.endAction() }
        relativeCalibration = nil
        try await checkCalibrationGeometry()
        guard let viewport = calibrationViewport,
              observed.count == BluetoothRelativeCalibrationProbe.allCases.count,
              observed.allSatisfy({ relativeProbeReceipts[$0.probe]?.token == $0.receiptToken }) else { throw DeviceControlError.staleFrame }
        guard observed.allSatisfy({ relativeProbeReceipts[$0.probe]?.matches($0) == true }) else { throw DeviceControlError.invalidCoordinates }
        relativeCalibration = try BluetoothRelativeDragCalibration(observed: observed,
            viewport: DevicePoint(x: Double(viewport.size.width), y: Double(viewport.size.height)))
        relativeProbeReceipts.removeAll()
        onChange?()
    }

    public func markKeyboardVerified() async throws {
        guard isCalibrating, calibration != nil, !operations.isBusy, releaseToken == nil else { throw DeviceControlError.busy }
        try operations.beginExclusive(); defer { operations.endAction() }
        try await checkCalibrationGeometry()
        keyboardVerified = true; isCalibrating = false
        calibrationFrame = nil; calibrationWindow = nil; calibrationView = nil; calibrationViewport = nil
        onChange?()
    }

    public func cancelCalibration() async {
        epoch = UUID(); clearCalibration()
        let token = UUID(); releaseToken = token
        await releaseHeldInput()
        if releaseToken == token { releaseToken = nil }
        onChange?()
    }

    private func checkCalibrationGeometry() async throws {
        try Task.checkCancellation()
        guard isConnected, isCalibrating, releaseToken == nil,
              let window = calibrationWindow, let view = calibrationView,
              let binding = calibrationViewport,
              try Viewport(window: window, view: view) == binding else { throw DeviceControlError.staleFrame }
        let token = epoch, current = try await observeOffMain()
        try requireEpoch(token)
        guard let original = calibrationFrame, original.sessionID == current.sessionID,
              original.orientation == current.orientation,
              original.screenshot.width == current.screenshot.width,
              original.screenshot.height == current.screenshot.height, binding.matches(current) else { throw DeviceControlError.staleFrame }
    }
    private func screenStore() throws -> ScreenBroadcastStore {
        if let store { return store }
        do { let value = try ScreenBroadcastStore(); store = value; return value }
        catch { throw DeviceControlError.connection(message("bluetooth.appGroupUnavailable")) }
    }
    /// UI accessors never open the App Group files. Owners can refresh screen
    /// metadata without sending a BLE INFO command alongside input.
    public func refreshScreenState() async {
        let token = UUID(); screenReadToken = token
        guard UIApplication.shared.isProtectedDataAvailable, let source = try? screenStore() else {
            publishScreenState(nil, token: token); return
        }
        let state = await Task.detached(priority: .utility) { source.state() }.value
        publishScreenState(state, token: token)
    }
    private func publishScreenState(_ state: ScreenBroadcastState?, token: UUID) {
        guard screenReadToken == token else { return }
        let previous = screenState
        cachedScreenState = UIApplication.shared.isProtectedDataAvailable ? state : nil
        cachedScreenUptime = ProcessInfo.processInfo.systemUptime
        // Once an observed session/geometry change or end invalidates the mapping,
        // returning to its old geometry must still require a fresh check.
        // Temporary read/activity gaps block readiness without proving a change.
        if let state = cachedScreenState, let calibration, calibration.isInvalidated(by: state) { clearCalibration() }
        if previous != screenState { onChange?() }
    }
    private func observeOffMain() async throws -> ObservedFrame {
        guard UIApplication.shared.isProtectedDataAvailable else { throw DeviceControlError.serviceUnavailable(.screen) }
        let source = try screenStore()
        let token = UUID(); screenReadToken = token
        do {
            let (frame, state) = try await Task.detached {
                let reading = try source.readCurrentFrame(), value = reading.frame
                let state = ScreenBroadcastState(phase: .active, sessionID: value.sessionID, updatedAt: reading.confirmedAt,
                    frameID: value.frameID, orientation: value.orientation, width: value.width, height: value.height)
                return (ObservedFrame(reading), state)
            }.value
            guard UIApplication.shared.isProtectedDataAvailable else { throw DeviceControlError.serviceUnavailable(.screen) }
            publishScreenState(state, token: token)
            return frame
        } catch {
            await refreshScreenState()
            throw DeviceControlError.serviceUnavailable(.screen)
        }
    }
    /// A frame captured after `uptime`, or an earlier frame the extension has
    /// confirmed unchanged for longer than its publish interval since then, so
    /// a screen change caused by the last action would already be pending.
    private func freshFrame(after uptime: TimeInterval, token: UUID) async throws -> ObservedFrame {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        while true {
            try requireEpoch(token)
            let frame = try await observeOffMain()
            try requireEpoch(token)
            if frame.capturedUptime > uptime || frame.observedUptime > uptime + Self.unchangedScreenSettle { return frame }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DeviceControlError.staleFrame }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private static let unchangedScreenSettle: TimeInterval = 0.75
    private func beginAction(allowCalibration: Bool = false) async throws {
        let token = epoch
        try await operations.beginAction()
        do {
            try requireEpoch(token)
            guard isConnected else { throw DeviceControlError.notConnected }
            guard releaseToken == nil, !isCalibrating || allowCalibration else { throw DeviceControlError.busy }
        } catch { operations.endAction(); throw error }
    }
    private func consumeCalibrationObservation(_ id: UUID) async throws -> (ObservedFrame, Calibration) {
        let decision = calibrationObservation; calibrationObservation = nil
        // This is exclusively the owned UIKit calibration field; model actions
        // consume GuardedDevice grants instead. Reuse the central age rule.
        guard let decision, decision.frame.screenshot.frameID == id,
              decision.frame.observedUptime > lastDispatchedUptime,
              let calibration, calibration.matches(decision.frame) else {
            throw DeviceControlError.staleFrame
        }
        let token = epoch, frame = decision.frame, current = try await observeOffMain()
        try requireEpoch(token)
        guard calibration.matches(current),
              FrameGrant.permits(decisionIssuedUptime: decision.issuedUptime,
                  currentConfirmedUptime: current.observedUptime, now: ProcessInfo.processInfo.systemUptime) else {
            throw DeviceControlError.staleFrame
        }
        return (frame, calibration)
    }
    private func requireConnectionEpoch(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !isHardwareStopLatched else { throw BluetoothBoardError.hardwareStopped }
        guard token == epoch, board.state == .ready, releaseToken == nil else { throw DeviceControlError.notConnected }
    }
    private func requireEpoch(_ token: UUID) throws {
        try requireConnectionEpoch(token)
        guard isConnected else { throw DeviceControlError.notConnected }
    }
    private func requireCurrent(_ mapping: Calibration, token: UUID) async throws {
        try requireEpoch(token)
        let current = try await observeOffMain()
        try requireEpoch(token)
        guard mapping.matches(current) else { throw DeviceControlError.staleFrame }
    }
    private func absolute(_ point: DevicePoint, pressed: Bool) async throws {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { throw DeviceControlError.invalidCoordinates }
        let x = UInt16((point.x * 32767).rounded()), y = UInt16((point.y * 32767).rounded())
        lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
        defer { lastDispatchedUptime = ProcessInfo.processInfo.systemUptime }
        _ = try await board.command(opcode: 5, payload: [UInt8(truncatingIfNeeded: x), UInt8(x >> 8), UInt8(truncatingIfNeeded: y), UInt8(y >> 8), pressed ? 1 : 0])
    }
    private func sendRelativeStroke(_ stroke: BluetoothRelativeStroke, token: UUID) async throws {
        try requireEpoch(token)
        lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
        defer { lastDispatchedUptime = ProcessInfo.processInfo.systemUptime }
        let receipt = try await board.command(opcode: 10, payload: stroke.payload)
        guard receipt.emittedReports == stroke.steps + 2 else { throw DeviceControlError.deliveryUnknown(message("bluetooth.interrupted")) }
        do { try requireEpoch(token) }
        catch { throw DeviceControlError.deliveryUnknown(message("bluetooth.interrupted")) }
    }
    /// iOS may ignore a repeated identical absolute report after relative input.
    /// Both reports are unpressed and stay inside the already granted geometry.
    private func repositionRelativePointer(_ point: DevicePoint, mapping: Calibration?, token: UUID) async throws {
        let nudge = DevicePoint(x: point.x <= 0.985 ? point.x + 0.015 : point.x - 0.015, y: point.y)
        try await absolute(nudge, pressed: false)
        try await Task.sleep(for: .milliseconds(32))
        if let mapping { try await requireCurrent(mapping, token: token) }
        else { try requireEpoch(token); try await checkCalibrationGeometry() }
        try await absolute(point, pressed: false)
    }
    private func updateRelativeReadiness(_ flags: UInt8) {
        supportsRelativeDrag = flags & BluetoothBoardProtocol.relativeStrokeSupportFlag != 0
        isRelativeDragReady = supportsRelativeDrag && flags & BluetoothBoardProtocol.relativeStrokeReadyFlag != 0
        if !isRelativeDragReady { relativeCalibration = nil; relativeProbeReceipts.removeAll() }
    }
    private func release(_ point: DevicePoint, token: UUID) async throws {
        do {
            try await Task.sleep(for: .milliseconds(40))
            try requireEpoch(token)
            try await absolute(point, pressed: false)
        } catch {
            await releaseHeldInput()
            throw DeviceControlError.deliveryUnknown(message("bluetooth.interrupted"))
        }
    }
    private func releaseHeldInput() async {
        let client = board
        await Task { @MainActor in if client.state == .ready { _ = try? await client.stop() } }.value
        lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
    }
    private func clearCalibration() {
        geometryRevision = UUID(); observedGeometry = nil
        calibration = nil; calibrationObservation = nil; calibrationFrame = nil; isCalibrating = false; keyboardVerified = false
        relativeCalibration = nil; relativeProbeReceipts.removeAll()
        calibrationWindow = nil; calibrationView = nil; calibrationViewport = nil
    }
    private func message(_ key: String) -> String { NSLocalizedString(key, tableName: "BluetoothControl", bundle: .module, comment: "") }

    struct ObservedFrame: Sendable {
        let screenshot: DeviceScreenshot
        let sessionID: UUID
        let orientation: ScreenBroadcastOrientation
        let capturedUptime: TimeInterval
        /// The latest time this frame was known to be the current screen.
        let observedUptime: TimeInterval
        /// Every observation gets its own ID. A confirmed unchanged screen can be
        /// observed again after an action, but each capture still authorizes one.
        init(_ reading: ScreenBroadcastReading) {
            let frame = reading.frame
            screenshot = DeviceScreenshot(frameID: UUID(), capturedAt: frame.capturedAt,
                width: frame.width, height: frame.height, mimeType: "image/jpeg", data: frame.jpegData)
            sessionID = frame.sessionID; orientation = frame.orientation
            capturedUptime = frame.capturedUptime; observedUptime = reading.confirmedUptime
        }
    }

    /// Validation coordinates use the whole broadcast display. Resizable iPad
    /// windows must not silently train a mapping in their smaller local space.
    private struct Viewport: Equatable {
        let size: CGSize
        let orientation: UIInterfaceOrientation
        @MainActor init(window: UIWindow, view: UIView) throws {
            guard UIApplication.shared.applicationState == .active, view.window === window,
                  let scene = window.windowScene, scene.activationState == .foregroundActive else {
                throw DeviceControlError.staleFrame
            }
            let direction = scene.effectiveGeometry.interfaceOrientation
            let screen = scene.screen
            let physical = screen.bounds.size
            let expected = direction.isLandscape
                ? CGSize(width: max(physical.width, physical.height), height: min(physical.width, physical.height))
                : CGSize(width: min(physical.width, physical.height), height: max(physical.width, physical.height))
            func near(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs-rhs) <= 1 }
            let rect = view.convert(view.bounds, to: window)
            let onScreen = window.convert(window.bounds, to: screen.coordinateSpace)
            let screenBounds = screen.coordinateSpace.bounds
            guard direction != .unknown,
                  near(window.bounds.width, expected.width), near(window.bounds.height, expected.height),
                  near(rect.minX, window.bounds.minX), near(rect.minY, window.bounds.minY),
                  near(rect.width, expected.width), near(rect.height, expected.height),
                  near(onScreen.minX, screenBounds.minX), near(onScreen.minY, screenBounds.minY),
                  near(onScreen.width, screenBounds.width), near(onScreen.height, screenBounds.height) else {
                throw DeviceControlError.connection(NSLocalizedString("bluetooth.fullScreenRequired", tableName: "BluetoothControl", bundle: .module, comment: ""))
            }
            size = expected; orientation = direction
        }
        func matches(_ frame: ObservedFrame) -> Bool {
            abs(size.width / size.height - Double(frame.screenshot.width) / Double(frame.screenshot.height)) < 0.01
        }
    }

    struct Calibration {
        let sessionID: UUID
        let orientation: ScreenBroadcastOrientation
        let width: Int, height: Int
        let origin: DevicePoint, xAxis: DevicePoint, yAxis: DevicePoint
        init(observed: [DevicePoint], frame: ObservedFrame) throws {
            guard observed.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { throw DeviceControlError.invalidCoordinates }
            xAxis = DevicePoint(x: (observed[1].x-observed[0].x)*2, y: (observed[1].y-observed[0].y)*2)
            yAxis = DevicePoint(x: (observed[2].x-observed[0].x)*2, y: (observed[2].y-observed[0].y)*2)
            origin = DevicePoint(x: observed[0].x - 0.25*xAxis.x - 0.25*yAxis.x, y: observed[0].y - 0.25*xAxis.y - 0.25*yAxis.y)
            let determinant = xAxis.x*yAxis.y-xAxis.y*yAxis.x
            let expected = DevicePoint(x: origin.x+0.62*xAxis.x+0.61*yAxis.x, y: origin.y+0.62*xAxis.y+0.61*yAxis.y)
            guard abs(determinant) > 0.4, abs(determinant) < 1.6,
                  hypot(expected.x-observed[3].x, expected.y-observed[3].y) < 0.025 else { throw DeviceControlError.invalidCoordinates }
            sessionID = frame.sessionID; orientation = frame.orientation
            width = frame.screenshot.width; height = frame.screenshot.height
        }
        func matches(_ frame: ObservedFrame) -> Bool {
            frame.sessionID == sessionID && frame.orientation == orientation && frame.screenshot.width == width && frame.screenshot.height == height
        }
        func matches(_ state: ScreenBroadcastState?) -> Bool {
            guard let state else { return false }
            return state.isActive && state.sessionID == sessionID && state.orientation == orientation
                && state.width == width && state.height == height
        }
        func isInvalidated(by state: ScreenBroadcastState) -> Bool {
            state.phase == .ended || state.sessionID.map { $0 != sessionID } == true
                || state.orientation.map { $0 != orientation } == true
                || state.width.map { $0 != width } == true || state.height.map { $0 != height } == true
        }
        func hidPoint(_ point: DevicePoint, in frame: DeviceScreenshot) throws -> DevicePoint {
            guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.x < Double(frame.width), point.y >= 0, point.y < Double(frame.height) else { throw DeviceControlError.invalidCoordinates }
            let x = point.x/Double(frame.width)-origin.x, y = point.y/Double(frame.height)-origin.y
            let d = xAxis.x*yAxis.y-xAxis.y*yAxis.x
            let result = DevicePoint(x: (x*yAxis.y-y*yAxis.x)/d, y: (y*xAxis.x-x*xAxis.y)/d)
            guard (0...1).contains(result.x), (0...1).contains(result.y) else { throw DeviceControlError.invalidCoordinates }
            return result
        }
    }
}
#endif
