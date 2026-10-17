import EiscueDeviceCore
import Foundation

/// Pixel publication does not revoke a single-use model observation. Only
/// transport, liveness and the calibration coordinate space affect this gate.
struct BluetoothSessionEventProjection {
    struct Geometry: Equatable {
        let sessionID: UUID
        let orientation: ScreenBroadcastOrientation
        let width: Int
        let height: Int
    }
    struct Snapshot: Equatable {
        let boardState: BluetoothBoardClient.State
        let connected: Bool
        let hardwareStopped: Bool
        let sharing: Bool
        let geometry: Geometry?

        @MainActor init(controller: BluetoothDeviceController) {
            self.init(boardState: controller.board.state, connected: controller.isConnected,
                hardwareStopped: controller.isHardwareStopLatched, screen: controller.screenState)
        }
        init(boardState: BluetoothBoardClient.State = .ready, connected: Bool = true,
             hardwareStopped: Bool = false, screen: ScreenBroadcastState?) {
            self.boardState = boardState; self.connected = connected; self.hardwareStopped = hardwareStopped
            sharing = screen?.isActive == true
            if let sessionID = screen?.sessionID, let orientation = screen?.orientation,
               let width = screen?.width, let height = screen?.height {
                geometry = Geometry(sessionID: sessionID, orientation: orientation, width: width, height: height)
            } else { geometry = nil }
        }
        init(boardState: BluetoothBoardClient.State = .ready, connected: Bool = true,
             hardwareStopped: Bool = false, sharing: Bool = true, geometry: Geometry?) {
            self.boardState = boardState; self.connected = connected
            self.hardwareStopped = hardwareStopped; self.sharing = sharing; self.geometry = geometry
        }
    }
    private var previous: Snapshot?

    @MainActor mutating func update(_ current: Snapshot, session: DeviceSession) -> DeviceSession.ExternalEvent? {
        // Setup owns the device, but does not make transport or sharing loss expected.
        update(current, acceptsEvents: session.selectedMethod == .bluetoothBoard && !session.expectsTransportChanges)
    }

    mutating func update(_ current: Snapshot, acceptsEvents: Bool = true) -> DeviceSession.ExternalEvent? {
        defer { previous = current }
        guard acceptsEvents, let previous, !current.hardwareStopped, !previous.hardwareStopped else { return nil }
        if current.boardState != previous.boardState, case .failed(let error) = current.boardState,
           [.authenticationFailed, .authenticationKeyUnavailable, .enrollmentClosed, .enrollmentConflict].contains(error) {
            return .authenticationFailed
        }
        if (previous.connected && !current.connected) || (previous.boardState == .ready && current.boardState != .ready) {
            return .transportLost
        }
        guard current.connected else { return nil }
        if previous.sharing && !current.sharing { return .screenSharingStopped }
        if previous.sharing, current.sharing, previous.geometry != current.geometry { return .geometryChanged }
        return nil
    }
}

extension AppModel {
    func handleBluetoothSessionChange() {
        bluetoothRevision += 1
        let event = bluetoothSessionEvents.update(.init(controller: bluetoothController), session: deviceSession)
        if let event {
            let reason = switch event {
            case .authenticationFailed:
                if case .failed(let error) = bluetoothController.board.state { error.localizedDescription }
                else { BluetoothBoardError.authenticationFailed.localizedDescription }
            case .geometryChanged: DeviceControlError.staleFrame.localizedDescription
            default: String(localized: "bluetooth.stopped", table: "Bluetooth")
            }
            deviceSession.handle(event, expected: deviceSession.identity, status: .unavailable(reason: reason))
            if event == .authenticationFailed || event == .transportLost {
                deviceConnectionError = reason; connectionMessage = reason
            }
        }
        syncBoardCompanion()
    }
}
