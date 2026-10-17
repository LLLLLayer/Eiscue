import Foundation

/// The sole issuer of single-use device observations. Both native and HID routes
/// share the same admission, age, geometry, validation and outcome rules.
@MainActor public final class GuardedDevice {
    private let actuator: any DeviceActuator
    private let uptime: @Sendable () -> TimeInterval
    private var grant: FrameGrant?
    private var busy = false
    private var outcomeUncertain = false
    private var disconnectCount = 0
    private var epoch = UUID()

    public nonisolated init(actuator: any DeviceActuator, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.actuator = actuator; self.uptime = uptime
    }
    public func status() async -> DeviceStatus {
        if outcomeUncertain { return .unavailable(reason: DeviceControlError.connectionLost.localizedDescription) }
        return await actuator.cachedStatus()
    }
    func connectionDidOpen() { invalidate(); outcomeUncertain = false }
    public func probe() async -> DeviceStatus {
        guard !busy, !outcomeUncertain else { return await status() }
        busy = true; defer { busy = false }
        let state = await actuator.probe()
        if case .unavailable = state { invalidate() }
        return state
    }
    public func invalidate() { grant = nil; epoch = UUID() }
    public func captureScreenshot() async throws -> DeviceScreenshot {
        try begin(); defer { busy = false }
        grant = nil
        let token = epoch
        let screenshot = try await actuator.capture()
        let state = try await actuator.frameState()
        try Task.checkCancellation()
        guard token == epoch, state.isLive,
              screenshot.width > 1, screenshot.height > 1,
              screenshot.width == state.geometry.width, screenshot.height == state.geometry.height,
              screenshot.geometry == state.geometry,
              streamIsLive(state, now: uptime()) else { throw DeviceControlError.staleFrame }
        let issued = uptime()
        let observation = DeviceScreenshot(frameID: UUID(), capturedAt: screenshot.capturedAt,
            width: screenshot.width, height: screenshot.height, mimeType: screenshot.mimeType,
            data: screenshot.data, geometry: state.geometry)
        grant = FrameGrant(frameID: observation.frameID, geometry: state.geometry, issuedUptime: issued)
        return observation
    }
    public func perform(_ action: DeviceAction, frameID: UUID) async throws {
        try begin(); defer { busy = false }
        guard let grant, grant.frameID == frameID else { throw DeviceControlError.staleFrame }
        try DeviceInputValidation.action(action, geometry: grant.geometry)
        let token = epoch
        let state: DeviceFrameState
        do { state = try await actuator.frameState() }
        catch { invalidate(); throw error }
        try Task.checkCancellation()
        guard token == epoch, state.isLive, state.geometry == grant.geometry,
              FrameGrant.permits(decisionIssuedUptime: grant.issuedUptime, currentConfirmedUptime: state.confirmedUptime, now: uptime()) else {
            invalidate(); throw DeviceControlError.staleFrame
        }
        guard case .ready(let capabilities) = await actuator.cachedStatus() else { invalidate(); throw DeviceControlError.notConnected }
        guard capabilities.contains(action.capability) else { throw DeviceControlError.capabilityUnavailable(action.capability) }
        try Task.checkCancellation()
        guard token == epoch else { throw DeviceControlError.staleFrame }
        self.grant = nil
        let previousDisconnects = disconnectCount
        let result: SubmissionResult
        do { result = try await actuator.perform(action, frame: grant) }
        catch {
            await stopAfterUnknown(previousDisconnects: previousDisconnects)
            if let failure = error as? DeviceControlError, failure.isDeliveryUnknown { throw failure }
            throw DeviceControlError.deliveryUnknown("")
        }
        switch result {
        case .notSubmitted(let failure): throw failure
        case .submitted:
            guard token == epoch, !Task.isCancelled else {
                await stopAfterUnknown(previousDisconnects: previousDisconnects)
                throw DeviceControlError.deliveryUnknown("")
            }
        }
    }
    public func listApplications() async throws -> [DeviceApplication] {
        try begin(); defer { busy = false }
        guard case .ready(let capabilities) = await actuator.cachedStatus() else { throw DeviceControlError.notConnected }
        guard capabilities.contains(.listApplications) else { throw DeviceControlError.capabilityUnavailable(.listApplications) }
        return try await actuator.listApplications()
    }
    public func finishTask() async throws {
        try begin(allowUncertain: true); defer { busy = false }
        invalidate()
        try await actuator.releaseInput()
    }
    public func disconnect() async -> ReleaseConfirmation {
        disconnectCount += 1
        invalidate()
        // Disconnect must also invalidate an in-flight submission, even while
        // the serialization gate is held by that submission.
        return await actuator.disconnect()
    }
    private func stopAfterUnknown(previousDisconnects: Int) async {
        outcomeUncertain = true; invalidate()
        if disconnectCount == previousDisconnects { _ = await disconnect() }
    }
    private func begin(allowUncertain: Bool = false) throws {
        try Task.checkCancellation()
        guard allowUncertain || !outcomeUncertain else { throw DeviceControlError.connectionLost }
        guard !busy else { throw DeviceControlError.busy }
        busy = true
    }
    private func streamIsLive(_ state: DeviceFrameState, now: TimeInterval) -> Bool {
        guard let confirmation = state.confirmedUptime else { return true }
        let age = now - confirmation
        return age.isFinite && age >= 0 && age <= ScreenBroadcastStore.maximumFrameAge
    }
}
