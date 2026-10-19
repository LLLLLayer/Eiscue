import SwiftUI

@main
struct EiscueApp: App {
    #if DEBUG && !EISCUE_HID_ONLY
    @State private var model = DebugNetworkRunAcceptance.makeModel()
    #else
    @State private var model = AppModel()
    #endif
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    private var networkRunUsesAcceptanceTarget: Bool {
        #if !EISCUE_HID_ONLY
        DebugNetworkRunAcceptance.usesAcceptanceTarget
        #else
        false
        #endif
    }
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if DebugDevicePageFixture.isEnabled {
                    RootView(initialDestination: .device)
                } else if ProcessInfo.processInfo.arguments.contains("--bluetooth-setup-check")
                            || ProcessInfo.processInfo.arguments.contains("--system-pairing-check") {
                    RootView(initialDestination: .device)
                } else if ProcessInfo.processInfo.arguments.contains("--ble-device-check") {
                    BLEDeviceCheckView()
                } else if ProcessInfo.processInfo.arguments.contains("--owned-device-check") {
                    OwnedDeviceCheckView()
                } else if networkRunUsesAcceptanceTarget {
                    #if !EISCUE_HID_ONLY
                    DebugNetworkRunAcceptanceTargetView()
                    #else
                    RootView()
                    #endif
                } else if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                          ProcessInfo.processInfo.arguments.contains("--message-sharing-fixture") {
                    MessageSharingFixtureView()
                } else { RootView() }
                #else
                RootView()
                #endif
            }
                .environment(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .tint(EiscueStyle.accent)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ble-device-check") { return }
                    if DebugDevicePageFixture.isEnabled {
                        model.installLocalDevicePageFixture()
                        return
                    }
                    if DebugDevicePageFixture.isOnboardingEnabled {
                        model.installOnboardingPairingFixture()
                        return
                    }
                    #endif
                    await model.load()
                    #if DEBUG && !EISCUE_HID_ONLY
                    await DebugNetworkRunAcceptance.runIfRequested(model: model)
                    #endif
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--long-conversation-fixture") {
                        model.installLongConversationFixture()
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--tool-image-preview-fixture") {
                        await model.installToolImagePreviewFixture()
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--unknown-outcome-fixture") {
                        await model.installUnknownOutcomeFixture()
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--board-stop-notice-fixture") {
                        await model.selectDeviceConnectionMethod(.bluetoothBoard)
                        model.handleBoardHardwareStop()
                    }
                    // Opens the real setup UI for the explicitly requested device
                    // validation; it never grants screen sharing or sends input.
                    if ProcessInfo.processInfo.arguments.contains("--bluetooth-setup-check") {
                        await model.selectDeviceConnectionMethod(.bluetoothBoard)
                        if ProcessInfo.processInfo.arguments.contains("--bluetooth-input-bluetooth") {
                            await model.selectBluetoothInputRoute(.bluetooth)
                        }
                        if ProcessInfo.processInfo.arguments.contains("--bluetooth-connect-once") {
                            await model.enableDeviceControl()
                        }
                    }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ble-device-check") { return }
                    if DebugDevicePageFixture.isEnabled { return }
                    if DebugDevicePageFixture.isOnboardingEnabled { return }
                    #endif
                    model.sceneChanged(phase)
                }
        }
    }
}
