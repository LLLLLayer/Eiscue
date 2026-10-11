import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showsAdvanced = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Button {
                    model.showsModelSettings = true
                } label: {
                    HStack {
                        SettingsRowLabel(String(localized: "settings.model", table: "Runtime"), systemImage: "sparkle")
                        Spacer()
                        Text(model.hasConfiguredModel ? model.modelSettings.model : String(localized: "settings.unconfigured", table: "Runtime"))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityIdentifier("modelSettingsButton")
                NavigationLink {
                    SkillsView()
                } label: {
                    SettingsRowLabel(String(localized: "settings.skills", table: "Runtime"), systemImage: "books.vertical")
                }
                .accessibilityIdentifier("skillsNavigationLink")
                NavigationLink {
                    RunHistoryView()
                } label: {
                    SettingsRowLabel(String(localized: "settings.runs", table: "Runtime"), systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("runHistoryNavigationLink")
                NavigationLink {
                    StickerGalleryView()
                } label: {
                    SettingsRowLabel(String(localized: "composer.stickers", table: "Composer"), systemImage: "face.smiling")
                }
                .accessibilityIdentifier("stickerGalleryNavigationLink")
            }
            .listRowBackground(EiscueStyle.surface)

            Section {
                Picker(selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                } label: {
                    SettingsRowLabel(String(localized: "settings.appearance", table: "Runtime"), systemImage: "circle.lefthalf.filled")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("appearancePicker")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    LabeledContent {
                        Text(String(localized: "settings.system_language", table: "Runtime"))
                            .foregroundStyle(.secondary)
                    } label: {
                        SettingsRowLabel(String(localized: "settings.language", table: "Runtime"), systemImage: "globe")
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("appLanguageSettingsButton")
                NavigationLink {
                    TaskSettingsView()
                } label: {
                    SettingsRowLabel(String(localized: "settings.taskStatus"), systemImage: "bell")
                }
                .accessibilityIdentifier("taskStatusSettingsButton")
            }
            .listRowBackground(EiscueStyle.surface)

            Section {
                Button {
                    model.showsOnboarding = true
                } label: {
                    SettingsRowLabel(String(localized: "settings.showGuide"), systemImage: "book.closed")
                }
                .foregroundStyle(.primary)
                .disabled(model.isBusy)
                .accessibilityIdentifier("showOnboardingButton")
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsRowLabel(String(localized: "settings.about", table: "Runtime"), systemImage: "info.circle")
                }
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    Toggle(isOn: $model.hapticsEnabled) {
                        SettingsRowLabel(String(localized: "settings.haptics", table: "Runtime"), systemImage: "hand.tap")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("hapticsToggle")
                    LabeledContent {
                        Text(String.localizedStringWithFormat(String(localized: "settings.conversation_count", table: "Runtime"), model.conversations.count))
                    } label: {
                        SettingsRowLabel(String(localized: "settings.conversations", table: "Runtime"), systemImage: "bubble.left.and.bubble.right")
                    }
                    Text(String(localized: "settings.data_footer", table: "Runtime"))
                        .font(.caption).foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel(String(localized: "settings.advanced"), systemImage: "slider.horizontal.3")
                        .accessibilityIdentifier("settingsAdvancedOptions")
                }
            }
            .listRowBackground(EiscueStyle.surface)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(EiscueStyle.background)
        .navigationTitle(String(localized: "settings.title", table: "Runtime"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TaskSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showsDetails = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { model.taskNotifications.isEnabled },
                    set: { enabled in Task { await model.taskNotifications.setEnabled(enabled) } }
                )) {
                    SettingsRowLabel(String(localized: "settings.task_notifications", table: "Runtime"), systemImage: "bell.badge")
                }
                .disabled(model.taskNotifications.isRequestingAuthorization)
                .accessibilityIdentifier("taskNotificationsToggle")
                if let error = model.taskNotifications.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                } label: {
                    SettingsRowLabel(String(localized: "settings.notification_settings", table: "Runtime"), systemImage: "gearshape")
                }
            } footer: {
                Text("settings.taskStatusShort")
            }
            .listRowBackground(EiscueStyle.surface)
            Section {
                DisclosureGroup(isExpanded: $showsDetails) {
                    LabeledContent {
                        Text(String(localized: "settings.system_activity", table: "Runtime"))
                            .foregroundStyle(.secondary)
                    } label: {
                        SettingsRowLabel(String(localized: "settings.live_activity", table: "Runtime"), systemImage: "waveform.path")
                    }
                    .accessibilityIdentifier("backgroundStatusSummary")
                    Text(model.taskNotifications.authorizationDescription)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(localized: "settings.background_footer", table: "Runtime"))
                        .font(.caption).foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel(String(localized: "settings.backgroundDetails"), systemImage: "info.circle")
                        .accessibilityIdentifier("backgroundStatusDetails")
                }
            }
            .listRowBackground(EiscueStyle.surface)
        }
        .scrollContentBackground(.hidden)
        .background(EiscueStyle.background)
        .navigationTitle("settings.taskStatus")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.taskNotifications.refreshAuthorization() }
    }
}

private struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            IceMark(size: 92)
            VStack(spacing: 8) {
                Text("Eiscue")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(String(localized: "about.tagline", table: "Runtime"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Text(String(format: String(localized: "about.version", table: "Runtime"), version))
                .font(.caption)
                .foregroundStyle(.tertiary)
            VStack(spacing: 5) {
                Text(String(localized: "about.local_tunnel", table: "Runtime"))
                Text(String(localized: "about.attribution", table: "Runtime"))
                Link(String(localized: "about.source", table: "Runtime"), destination: URL(string: "https://github.com/jkcoxson/LocalDevVPN")!)
            }
            .font(.caption2).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer()
            Text(String(localized: "about.footer", table: "Runtime"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .background(EiscueStyle.background)
        .navigationTitle(String(localized: "about.title", table: "Runtime"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(EiscueStyle.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.primary)
        }
    }
}
