import SwiftUI

@main
struct EiscueApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .tint(EiscueStyle.accent)
                .task { await model.load() }
                .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
        }
    }
}
