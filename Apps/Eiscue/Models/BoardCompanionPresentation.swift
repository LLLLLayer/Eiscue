import EiscueDeviceCore
import Foundation

/// The board receives fixed phases and observed work counts, never model text,
/// conversation names or a guessed percentage of the user's goal.
enum BoardCompanionPresentation {
    static var language: BluetoothCompanionStatus.Language {
        let supported: [String: BluetoothCompanionStatus.Language] = ["en": .english, "zh-Hans": .simplifiedChinese]
        let selected = Bundle.preferredLocalizations(from: Array(supported.keys), forPreferences: Bundle.main.preferredLocalizations)
        return selected.first.flatMap { supported[$0] } ?? .english
    }

    static func task(_ run: RunRecord, currentTool: String, stopping: Bool,
                     finishing: Bool, language: BluetoothCompanionStatus.Language,
                     devicePhase: DeviceTaskPhase? = nil) -> BluetoothCompanionStatus {
        let completed = Set(run.events.filter { $0.kind == "tool.finished" }.map(\.id)).count
        let phase: BluetoothCompanionStatus.Phase
        if stopping || run.state == .interrupted { phase = .stopped }
        else if run.state == .failed { phase = .failed }
        else if run.state == .paused { phase = .waiting }
        else if run.state == .completed, run.endedAt != nil, !finishing { phase = .completed }
        else if finishing || run.state == .preparing || run.state == .completed { phase = .waiting }
        else if devicePhase == .observing || devicePhase == .verifying { phase = .observing }
        else if devicePhase == .deciding { phase = .thinking }
        else if devicePhase == .paused { phase = .waiting }
        else if devicePhase == .stopped { phase = .stopped }
        else {
            phase = DeviceToolSpec(rawValue: currentTool)?.companionPhase
                ?? (currentTool.isEmpty ? .thinking : .waiting)
        }
        return BluetoothCompanionStatus(phase: phase, language: language, completedActions: UInt16(clamping: completed))
    }

    static func setup(connected: Bool, sharing: Bool, ready: Bool, stopped: Bool,
                      language: BluetoothCompanionStatus.Language) -> BluetoothCompanionStatus {
        let phase: BluetoothCompanionStatus.Phase
        if stopped { phase = .stopped }
        else if !connected { phase = .idle }
        else if !sharing { phase = .needsScreenSharing }
        else if !ready { phase = .needsCalibration }
        else { phase = .ready }
        return BluetoothCompanionStatus(phase: phase, language: language, completedActions: 0)
    }
}
