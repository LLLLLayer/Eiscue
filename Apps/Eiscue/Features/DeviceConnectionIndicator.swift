import SwiftUI

enum ConnectionIndicatorState: Equatable {
    case unpaired, paired, connecting, ready, failed

    var title: String {
        let key: String.LocalizationValue = switch self {
        case .unpaired: "deviceBadge.unpaired"
        case .paired: "deviceBadge.paired"
        case .connecting: "deviceBadge.busy"
        case .ready: "deviceBadge.ready"
        case .failed: "deviceBadge.failed"
        }
        return String(localized: key, table: "Composer")
    }
    var color: Color {
        switch self {
        case .ready: Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.05, green: 0.48, blue: 0.20, alpha: 1)
        })
        case .unpaired, .paired, .failed: Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemRed : UIColor(red: 0.80, green: 0.08, blue: 0.12, alpha: 1)
        })
        case .connecting: .secondary
        }
    }
    static func resolve(isReady: Bool, isConnecting: Bool, hasIdentity: Bool, hasError: Bool) -> Self {
        if isConnecting { return .connecting }
        if hasError { return .failed }
        if isReady { return .ready }
        return hasIdentity ? .paired : .unpaired
    }
}

extension AppModel {
    var connectionIndicator: ConnectionIndicatorState {
        .resolve(isReady: isDeviceReady, isConnecting: isConnecting || isPairing || isManagingTunnel,
                 hasIdentity: hasPairingIdentity,
                 hasError: deviceConnectionError != nil || (deviceConnectionMethod == .localVPN && localTunnel.lastError != nil))
    }
}

struct DeviceConnectionIndicator: View {
    let state: ConnectionIndicatorState

    private var expression: EiscueHeadState {
        switch state {
        case .unpaired, .paired: .asleep
        case .connecting: .looking
        case .ready: .awake
        case .failed: .concerned
        }
    }

    var body: some View {
        EiscueHeadView(state: expression)
            .frame(width: 32, height: 32)
            // Keep the toolbar's standard glyph metrics aligned with the image viewer's close button.
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}
