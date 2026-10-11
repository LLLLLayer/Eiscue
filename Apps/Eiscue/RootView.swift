import SwiftUI

enum AppDestination: Hashable {
    case settings
    case device
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path: [AppDestination] = []
    @State private var showsSidebar = false
    @State private var wideSidebarIsExpanded = true

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let usesWideLayout = horizontalSizeClass == .regular && geometry.size.width >= 820
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if usesWideLayout && wideSidebarIsExpanded {
                        sidebar(isPersistent: true)
                            .frame(width: 300)
                        Divider()
                    }
                    NavigationStack(path: $path) {
                        AssistantView(openSidebar: {
                            if usesWideLayout {
                                withAnimation(.easeInOut(duration: 0.22)) { wideSidebarIsExpanded.toggle() }
                            } else {
                                setSidebarVisible(true)
                            }
                        })
                        .navigationDestination(for: AppDestination.self) { destination in
                            switch destination {
                            case .settings: SettingsView()
                            case .device: DeviceView()
                            }
                        }
                    }
                    .accessibilityHidden(showsSidebar && !usesWideLayout)
                }

                if showsSidebar && !usesWideLayout {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture { setSidebarVisible(false) }
                        .accessibilityHidden(true)
                    sidebar(isPersistent: false)
                        .frame(width: min(340, geometry.size.width * 0.86))
                        .frame(maxHeight: .infinity)
                        .background(EiscueStyle.background.ignoresSafeArea())
                        .shadow(color: .black.opacity(0.12), radius: 20, x: 8)
                        .transition(.move(edge: .leading))
                        .accessibilityAddTraits(.isModal)
                        .gesture(DragGesture(minimumDistance: 25).onEnded { value in
                            if value.translation.width < -70 { setSidebarVisible(false) }
                        })
                }
            }
            .accessibilityHidden(model.showsOnboarding && !model.isLoading)
            .allowsHitTesting(!model.showsOnboarding)
            .onChange(of: usesWideLayout) { _, isWide in
                showsSidebar = false
                if isWide { wideSidebarIsExpanded = true }
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

    private func sidebar(isPersistent: Bool) -> some View {
        ConversationSidebarView(
            selectConversation: { conversation in
                model.select(conversation)
                path.removeAll()
                setSidebarVisible(false)
            },
            newConversation: {
                model.newConversation()
                path.removeAll()
                setSidebarVisible(false)
            },
            openSettings: {
                path = [.settings]
                setSidebarVisible(false)
            },
            closeSidebar: isPersistent ? nil : { setSidebarVisible(false) }
        )
    }

    private func setSidebarVisible(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.22)) { showsSidebar = visible }
    }
}
