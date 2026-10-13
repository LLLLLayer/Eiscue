import EiscueDeviceKit
import Foundation

extension AppModel {
    func syncBoardCompanion(isFinishing: Bool = false) {
        guard deviceConnectionMethod == .bluetoothBoard, !isUpdatingBoardCompanion else { return }
        isUpdatingBoardCompanion = true
        defer { isUpdatingBoardCompanion = false }
        let language = BoardCompanionPresentation.language
        let status: BluetoothCompanionStatus
        if bluetoothController.isHardwareStopLatched {
            let completed = activeRun.map {
                BoardCompanionPresentation.task($0, currentTool: currentTool, stopping: true,
                                                finishing: true, language: language).completedActions
            } ?? companionLastStatus?.completedActions ?? 0
            companionTerminal = nil
            status = BluetoothCompanionStatus(phase: .stopped, language: language, completedActions: completed)
        } else if let run = activeRun {
            // Polls and controller callbacks can occur while final persistence
            // suspends. Only the owning run can clear this finalization gate.
            let finalizing = isFinishing || isStopping || companionFinalizingRunID == run.id
            status = BoardCompanionPresentation.task(run, currentTool: currentTool, stopping: stopRequested,
                                                     finishing: finalizing, language: language)
            // Retain a finalized outcome briefly; the next run always replaces it.
            if run.endedAt != nil, !finalizing {
                companionTerminal = (status, .now.advanced(by: .seconds(10)))
            } else { companionTerminal = nil }
        } else if let terminal = companionTerminal, ContinuousClock.now < terminal.until {
            status = terminal.status
        } else {
            companionTerminal = nil
            status = BoardCompanionPresentation.setup(connected: isBluetoothConnected, sharing: isBluetoothScreenShared,
                                                      ready: isDeviceReady, stopped: false, language: language)
        }
        companionLastStatus = status
        bluetoothController.updateCompanionStatus(status)
    }

    func handleBoardHardwareStop() {
        guard deviceConnectionMethod == .bluetoothBoard else { return }
        let reason = String(localized: "bluetooth.hardwareStopped", table: "Bluetooth")
        screenshot = nil
        deviceStatus = .unavailable(reason: reason)
        deviceConnectionError = reason
        connectionMessage = reason
        bluetoothRevision += 1
        companionTerminal = nil
        syncBoardCompanion()
        guard let runID = activeRun?.id else { return }
        deviceTools?.stop()
        Task { [weak self] in await self?.stop(expectedRunID: runID, reason: reason) }
    }
}
