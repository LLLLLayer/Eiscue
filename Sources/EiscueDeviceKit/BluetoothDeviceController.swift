import Foundation

enum BluetoothFrameAuthority {
    static func permits(sourceFrameID: UUID, capturedUptime: TimeInterval,
                        currentSourceFrameID: UUID, currentConfirmedUptime: TimeInterval,
                        now: TimeInterval) -> Bool {
        let capturedAge = now - capturedUptime, confirmedAge = now - currentConfirmedUptime
        guard capturedAge.isFinite, capturedAge >= 0,
              confirmedAge.isFinite, confirmedAge >= 0 else { return false }
        // The current reading was validated by ScreenBroadcastStore. A live
        // heartbeat for a newer buffer cannot extend an older observation.
        return capturedAge <= ScreenBroadcastStore.maximumFrameAge ||
            sourceFrameID == currentSourceFrameID && confirmedAge <= ScreenBroadcastStore.maximumFrameAge
    }
}

#if os(iOS)
import UIKit

/// BLE input and user-authorized ReplayKit observation. The host presents the
/// system broadcast picker and an owned calibration surface before enabling AI.
@MainActor
public final class BluetoothDeviceController: DeviceController {
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
    private var calibration: Calibration?
    private var calibrationFrame: ObservedFrame?
    private var latest: ObservedFrame?
    private weak var calibrationWindow: UIWindow?
    private weak var calibrationView: UIView?
    private var calibrationViewport: Viewport?
    private let operations = BluetoothOperationGate()
    private var releaseToken: UUID?
    private var epoch = UUID()
    private var keyboardAvailable = false
    private var keyboardVerified = false
    private var absoluteAvailable = false
    private var navigationAvailable = false
    private var lastDispatchedUptime: TimeInterval = -.infinity

    public init(board: BluetoothBoardClient = BluetoothBoardClient(), screenStore: ScreenBroadcastStore? = nil) {
        self.board = board; store = screenStore
        board.onStateChange = { [weak self] state in
            guard let self else { return }
            if state != .ready {
                if isConnected || isCalibrating { epoch = UUID() }
                isConnected = false; clearCalibration()
                outputInfo = nil; navigationAvailable = false
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

    public var screenState: ScreenBroadcastState? { try? screenStore().state() }
    public var isInputReady: Bool { isConnected && !isHardwareStopLatched && absoluteAvailable && keyboardAvailable }
    public var isPointerVerified: Bool {
        guard !isHardwareStopLatched, !isCalibrating, let calibration, let state = screenState else { return false }
        return state.isActive && state.sessionID == calibration.sessionID && state.orientation == calibration.orientation
            && state.width == calibration.width && state.height == calibration.height
    }

    public func status() async -> DeviceStatus {
        guard !isHardwareStopLatched else { return .unavailable(reason: BluetoothBoardError.hardwareStopped.localizedDescription) }
        guard isConnected else { return .unavailable(reason: message("bluetooth.connect")) }
        if releaseToken == nil, !isCalibrating, operations.beginStatus() {
            defer { operations.endStatus() }
            let token = epoch
            do {
                let receipt = try await board.command(opcode: 7)
                try requireEpoch(token)
                absoluteAvailable = receipt.emittedReports & 1 != 0
                keyboardAvailable = receipt.emittedReports & 2 != 0
                if outputInfo != nil {
                    let info = try await readOutputInfo(token: token)
                    guard info.selectedRoute == inputRoute else { throw DeviceControlError.connection(message("bluetooth.outputMismatch")) }
                    navigationAvailable = info.supportsNavigation
                }
                guard absoluteAvailable && keyboardAvailable else {
                    clearCalibration(); onChange?()
                    return .unavailable(reason: message(inputRoute == .usb ? "bluetooth.usbMissing" : "bluetooth.hidMissing"))
                }
            } catch {
                if let failure = error as? BluetoothBoardError, failure == .authenticationFailed { board.disconnect() }
                clearCalibration(); onChange?()
                return .unavailable(reason: error.localizedDescription)
            }
        }
        do {
            guard try screenStore().state().isActive else { return .unavailable(reason: message("bluetooth.share")) }
        } catch { return .unavailable(reason: error.localizedDescription) }
        guard isPointerVerified else { return .unavailable(reason: message("bluetooth.calibrate")) }
        var capabilities: Set<DeviceCapability> = [.screenshot, .tap, .swipe]
        if keyboardAvailable && keyboardVerified {
            capabilities.insert(.textInput)
            if navigationAvailable { capabilities.formUnion([.home, .keyboardNavigation]) }
        }
        return .ready(capabilities: capabilities)
    }

    public func hasPairingIdentity() async throws -> Bool { isConnected }

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
        epoch = UUID(); clearCalibration()
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
            throw error
        }
    }

    public func disconnect() async {
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
    }

    public func stopSharing() throws {
        epoch = UUID(); clearCalibration()
        let token = UUID(); releaseToken = token
        Task { @MainActor in
            await releaseHeldInput()
            if releaseToken == token { releaseToken = nil }
            onChange?()
        }
        try screenStore().requestStop(); onChange?()
    }

    public func captureScreenshot() async throws -> DeviceScreenshot {
        try await beginAction(allowCalibration: true); defer { operations.endAction() }
        let observation = try await freshFrame(after: lastDispatchedUptime, token: epoch)
        latest = observation
        return observation.screenshot
    }

    /// End a successful user-started task without discarding the checked
    /// connection. Only confirmed release permits preserving its calibration.
    public func finishTask() async throws {
        try await beginAction(); defer { operations.endAction() }
        let token = epoch
        latest = nil
        do {
            _ = try await board.stop()
            lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
            try requireEpoch(token)
            guard let calibration, calibration.matches(try observe()) else { throw DeviceControlError.staleFrame }
        } catch {
            await disconnect()
            throw error
        }
    }

    public func tap(at point: DevicePoint, frameID: UUID) async throws {
        try await beginAction(); defer { operations.endAction() }
        let (frame, mapping) = try consume(frameID)
        let position = try mapping.hidPoint(point, in: frame.screenshot)
        let token = epoch
        try await absolute(position, pressed: false)
        try requireCurrent(mapping, token: token)
        try await absolute(position, pressed: true)
        try await release(position, token: token)
    }

    public func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard seconds.isFinite, (0.1...2).contains(seconds) else { throw DeviceControlError.invalidDuration }
        try await beginAction(); defer { operations.endAction() }
        let (frame, mapping) = try consume(frameID)
        let start = try mapping.hidPoint(from, in: frame.screenshot), end = try mapping.hidPoint(to, in: frame.screenshot)
        let token = epoch
        try await absolute(start, pressed: false)
        do {
            try requireCurrent(mapping, token: token)
            try await absolute(start, pressed: true)
            let steps = max(2, Int(ceil(seconds / 0.06)))
            for step in 1...steps {
                try await Task.sleep(for: .seconds(seconds / Double(steps)))
                try requireCurrent(mapping, token: token)
                let fraction = Double(step) / Double(steps)
                let p = DevicePoint(x: start.x + (end.x-start.x)*fraction, y: start.y + (end.y-start.y)*fraction)
                try await absolute(p, pressed: true)
            }
            try await release(end, token: token)
        } catch {
            await releaseHeldInput()
            // A partial drag may have changed the screen. Never repeat it.
            throw DeviceControlError.deliveryUnknown(message("bluetooth.interrupted"))
        }
    }

    public func typeText(_ text: String, frameID: UUID) async throws {
        try await paste(text, frameID: frameID, validation: false)
    }

    /// Only available while the host's bound calibration target is visible.
    /// The host must observe the actual field value before markKeyboardVerified.
    public func pasteCalibrationText(_ text: String, frameID: UUID) async throws {
        try await paste(text, frameID: frameID, validation: true)
    }

    private func paste(_ text: String, frameID: UUID, validation: Bool) async throws {
        guard !text.isEmpty, text.utf8.count <= 8192 else { throw DeviceControlError.invalidText }
        try await beginAction(allowCalibration: validation); defer { operations.endAction() }
        let (_, mapping) = try consume(frameID)
        guard keyboardAvailable, validation ? isCalibrating : keyboardVerified else { throw DeviceControlError.unsupported }
        if validation { try checkCalibrationGeometry() }
        // Reading the pasteboard back fails while Eiscue is in the background,
        // which is the normal state during a cross-app task. A changed count
        // proves this write landed without reading any pasteboard content.
        let before = UIPasteboard.general.changeCount
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        guard UIPasteboard.general.changeCount != before else { throw DeviceControlError.connection(message("bluetooth.clipboard")) }
        try requireCurrent(mapping, token: epoch)
        lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
        defer { lastDispatchedUptime = ProcessInfo.processInfo.systemUptime }
        _ = try await board.command(opcode: 6, payload: [0x08, 0x19])
    }

    public func home() async throws {
        try await beginAction(); defer { operations.endAction() }
        guard isPointerVerified, keyboardAvailable, keyboardVerified, navigationAvailable else { throw DeviceControlError.unsupported }
        _ = try observe(); latest = nil
        try await sendKey(opcode: 6, payload: [0x08, 0x0B], token: epoch)
    }

    public func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws {
        try await beginAction(); defer { operations.endAction() }
        let (_, mapping) = try consume(frameID)
        guard keyboardAvailable, keyboardVerified, navigationAvailable else { throw DeviceControlError.unsupported }
        let token = epoch
        try requireCurrent(mapping, token: token)
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
        try checkCalibrationGeometry()
        try await absolute(p, pressed: false)
        try await Task.sleep(for: .milliseconds(180))
        try requireEpoch(token)
        try checkCalibrationGeometry()
        try await absolute(p, pressed: true)
        try await release(p, token: token)
    }

    /// Three corner samples fit an affine mapping, the fourth independently
    /// verifies it. Samples are normalized points observed by UIKit, not ACKs.
    public func completeCalibration(observed: [DevicePoint]) throws {
        guard isCalibrating, !operations.isBusy, releaseToken == nil, observed.count == 4 else { throw DeviceControlError.invalidCoordinates }
        try checkCalibrationGeometry()
        guard let original = calibrationFrame else { throw DeviceControlError.staleFrame }
        calibration = try Calibration(observed: observed, frame: original)
        onChange?()
    }

    public func markKeyboardVerified() throws {
        guard isCalibrating, calibration != nil, !operations.isBusy, releaseToken == nil else { throw DeviceControlError.busy }
        try checkCalibrationGeometry()
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

    private func checkCalibrationGeometry() throws {
        try Task.checkCancellation()
        guard isConnected, isCalibrating, releaseToken == nil,
              let window = calibrationWindow, let view = calibrationView,
              let binding = calibrationViewport,
              try Viewport(window: window, view: view) == binding else { throw DeviceControlError.staleFrame }
        let current = try observe()
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
    /// The current screen. An unchanged screen keeps its earlier frame while the
    /// extension heartbeat confirms that no newer content has been delivered.
    private func observe() throws -> ObservedFrame {
        let source = try screenStore()
        do { return ObservedFrame(try source.readCurrentFrame()) }
        catch { throw DeviceControlError.connection(message("bluetooth.share")) }
    }
    /// A frame captured after `uptime`, or an earlier frame the extension has
    /// confirmed unchanged for longer than its publish interval since then, so
    /// a screen change caused by the last action would already be pending.
    private func freshFrame(after uptime: TimeInterval, token: UUID) async throws -> ObservedFrame {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        while true {
            try requireEpoch(token)
            let frame = try observe()
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
    private func consume(_ id: UUID) throws -> (ObservedFrame, Calibration) {
        let frame = latest; latest = nil
        // One capture authorizes one action: `latest` is cleared above, and the
        // observation must postdate every input sent since it was taken.
        guard let frame, frame.screenshot.frameID == id, frame.observedUptime > lastDispatchedUptime,
              (0..<30).contains(ProcessInfo.processInfo.systemUptime - frame.observedUptime),
              let calibration, calibration.matches(frame) else {
            throw DeviceControlError.staleFrame
        }
        let current = try observe()
        guard calibration.matches(current),
              BluetoothFrameAuthority.permits(sourceFrameID: frame.sourceFrameID,
                  capturedUptime: frame.capturedUptime, currentSourceFrameID: current.sourceFrameID,
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
    private func requireCurrent(_ mapping: Calibration, token: UUID) throws {
        try requireEpoch(token)
        guard mapping.matches(try observe()) else { throw DeviceControlError.staleFrame }
    }
    private func absolute(_ point: DevicePoint, pressed: Bool) async throws {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { throw DeviceControlError.invalidCoordinates }
        let x = UInt16((point.x * 32767).rounded()), y = UInt16((point.y * 32767).rounded())
        lastDispatchedUptime = ProcessInfo.processInfo.systemUptime
        defer { lastDispatchedUptime = ProcessInfo.processInfo.systemUptime }
        _ = try await board.command(opcode: 5, payload: [UInt8(truncatingIfNeeded: x), UInt8(x >> 8), UInt8(truncatingIfNeeded: y), UInt8(y >> 8), pressed ? 1 : 0])
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
        calibration = nil; latest = nil; calibrationFrame = nil; isCalibrating = false; keyboardVerified = false
        calibrationWindow = nil; calibrationView = nil; calibrationViewport = nil
    }
    private func message(_ key: String) -> String { NSLocalizedString(key, tableName: "BluetoothControl", bundle: .module, comment: "") }

    private struct ObservedFrame {
        let screenshot: DeviceScreenshot
        let sourceFrameID: UUID
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
            sourceFrameID = frame.frameID
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

    private struct Calibration {
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
