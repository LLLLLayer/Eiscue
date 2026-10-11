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
        case .ready, .connecting: EiscueStyle.accent
        case .failed: .red
        case .unpaired, .paired: .secondary
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
                 hasIdentity: hasPairingIdentity, hasError: deviceConnectionError != nil || localTunnel.lastError != nil)
    }
}

struct DeviceConnectionIndicator: View {
    let state: ConnectionIndicatorState
    let isIPad: Bool
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: isIPad ? "ipad" : "iphone.gen3")
                .font(.system(size: 23)).frame(width: 34, height: 34)
            Group {
                switch state {
                case .ready: Image(systemName: "checkmark.circle.fill")
                case .failed: Image(systemName: "exclamationmark.circle.fill")
                case .unpaired: Image(systemName: "questionmark.circle.fill")
                case .paired: Image(systemName: "minus.circle.fill")
                case .connecting: ProgressView().controlSize(.mini)
                }
            }.font(.system(size: 12, weight: .semibold))
                .background(EiscueStyle.background, in: Circle()).offset(x: 2, y: 1)
        }.foregroundStyle(state.color).accessibilityHidden(true)
    }
}
