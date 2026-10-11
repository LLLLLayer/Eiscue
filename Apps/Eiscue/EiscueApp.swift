import SwiftUI

@main
struct EiscueApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ble-device-check") {
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
                    #endif
                    await model.load()
                }
                .onChange(of: scenePhase) { _, phase in
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ble-device-check") { return }
                    #endif
                    model.sceneChanged(phase)
                }
        }
    }
}
