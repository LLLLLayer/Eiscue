import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Tab("common.assistant", systemImage: "sparkle") {
                AssistantView()
            }
            Tab("common.device", systemImage: "iphone") {
                DeviceView()
            }
            Tab("common.settings", systemImage: "slider.horizontal.3") {
                SettingsView()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.showsOnboarding && !model.isLoading },
            set: { if !$0 { model.showsOnboarding = false } }
        )) {
            OnboardingView()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.showsModelSettings) { ModelSettingsView() }
        .alert("common.unableToComplete", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("common.understood", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
