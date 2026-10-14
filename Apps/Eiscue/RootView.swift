import SwiftUI

enum AppDestination: Hashable {
    case settings
    case device
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [AppDestination] = []
    @State private var showsSidebar = false
    @State private var wideSidebarIsExpanded = true
    @State private var sidebarDrag: CGFloat = 0
    @State private var isDraggingSidebar = false
    @State private var sidebarDragID = 0
    @State private var sidebarSettlementID = UUID()

    init(initialDestination: AppDestination? = nil) {
        _path = State(initialValue: initialDestination.map { [$0] } ?? [])
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let usesWideLayout = horizontalSizeClass == .regular && geometry.size.width >= 820
            let width = usesWideLayout ? 300.0 : min(340, geometry.size.width * 0.86)
            let isOpen = usesWideLayout ? wideSidebarIsExpanded : showsSidebar
            let revealedWidth = min(width, max(0, (isOpen ? width : 0) + sidebarDrag))
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if usesWideLayout && (wideSidebarIsExpanded || isDraggingSidebar) {
                        sidebar(isPersistent: true)
                            .frame(width: width)
                            .offset(x: revealedWidth - width)
                            .frame(width: revealedWidth, alignment: .leading).clipped()
                            .accessibilityHidden(!wideSidebarIsExpanded)
                        Divider()
                    }
                    NavigationStack(path: $path) {
                        AssistantView(sidebarDragID: sidebarDragID, openSidebar: {
                            if usesWideLayout {
                                withAnimation(.easeInOut(duration: 0.22)) { wideSidebarIsExpanded.toggle() }
                            } else {
                                setSidebarVisible(true)
                            }
                        })
                        .safeAreaInset(edge: .top, spacing: 0) { boardStopNotice }
                        .navigationDestination(for: AppDestination.self) { destination in
                            Group {
                                switch destination {
                                case .settings: SettingsView()
                                case .device: DeviceView()
                                }
                            }
                            .safeAreaInset(edge: .top, spacing: 0) { boardStopNotice }
                        }
                    }
                    .accessibilityHidden(showsSidebar && !usesWideLayout)
                }

                if !usesWideLayout && (showsSidebar || isDraggingSidebar) {
                    Color.black.opacity(0.22 * revealedWidth / width)
                        .ignoresSafeArea()
                        .onTapGesture { setSidebarVisible(false) }
                        .allowsHitTesting(showsSidebar)
                        .accessibilityHidden(true)
                    sidebar(isPersistent: false)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(EiscueStyle.background.ignoresSafeArea())
                        .shadow(color: .black.opacity(0.12), radius: 20, x: 8)
                        .offset(x: revealedWidth - width)
                        .transition(.move(edge: .leading))
                        .accessibilityAddTraits(.isModal)
                        .accessibilityHidden(!showsSidebar)
                        .allowsHitTesting(showsSidebar)

                }
            }
            .clipped()
            .gesture(SidebarDragGesture(isEnabled: path.isEmpty && !model.showsOnboarding,
                                        isOpen: isOpen, onChanged: { translation in
                if !isDraggingSidebar { sidebarDragID += 1; isDraggingSidebar = true }
                sidebarSettlementID = UUID()
                sidebarDrag = translation
            }, onEnded: { translation, velocity, cancelled in
                let projected = (isOpen ? width : 0) + translation + velocity * 0.16
                let visible = cancelled ? isOpen : projected > width / 2
                let settlementID = UUID()
                sidebarSettlementID = settlementID
                withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.9), completionCriteria: .removed) {
                    if usesWideLayout { wideSidebarIsExpanded = visible } else { showsSidebar = visible }
                    sidebarDrag = 0
                } completion: { if sidebarSettlementID == settlementID { isDraggingSidebar = false } }
            }))
            .accessibilityHidden(model.showsOnboarding && !model.isLoading)
            .allowsHitTesting(!model.showsOnboarding)
            .onChange(of: usesWideLayout) { _, isWide in
                showsSidebar = false; sidebarDrag = 0; isDraggingSidebar = false
                sidebarSettlementID = UUID()
                if isWide { wideSidebarIsExpanded = true }
            }
        }
        .toolImagePreviewHost()
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

    @ViewBuilder private var boardStopNotice: some View {
        if model.boardHardwareStopPending, model.deviceConnectionMethod == .bluetoothBoard,
           !model.showsOnboarding {
            BoardHardwareStopNotice()
                .frame(maxWidth: 600)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(EiscueStyle.background)
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
        let settlementID = UUID()
        sidebarSettlementID = settlementID
        if !visible { isDraggingSidebar = true }
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.9), completionCriteria: .removed) {
            showsSidebar = visible; sidebarDrag = 0
        } completion: { if sidebarSettlementID == settlementID { isDraggingSidebar = false } }
    }
}
