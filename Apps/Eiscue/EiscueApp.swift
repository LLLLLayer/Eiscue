import SwiftUI

@main
struct EiscueApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

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
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--long-conversation-fixture") {
                        model.installLongConversationFixture()
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--tool-image-preview-fixture") {
                        model.installToolImagePreviewFixture()
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
