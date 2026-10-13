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
    let isIPad: Bool
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: isIPad ? "ipad" : "iphone.gen3")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(.primary)
            Group {
                switch state {
                case .ready: Image(systemName: "checkmark")
                case .failed: Image(systemName: "exclamationmark")
                case .unpaired, .paired: Image(systemName: "xmark")
                case .connecting:
                    ProgressView().tint(state.color).controlSize(.mini)
                        .scaleEffect(0.7).frame(width: 10, height: 10)
                }
            }
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(state.color)
                .frame(width: 14, height: 14)
                .background(state.color.opacity(0.22), in: Circle())
                .overlay { Circle().strokeBorder(state.color.opacity(0.42), lineWidth: 0.5) }
                .offset(x: 5, y: 2)
        }.accessibilityHidden(true)
    }
}
