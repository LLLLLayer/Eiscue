import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var currentLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? Bundle.main.developmentLocalization ?? "en"
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

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
                        Text(model.selectedModelProfile?.displayName ?? String(localized: "settings.unconfigured", table: "Runtime"))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canManageModelProfiles)
                .accessibilityIdentifier("modelSettingsButton")
                NavigationLink {
                    SkillsView()
                } label: {
                    SettingsRowLabel(String(localized: "settings.skills", table: "Runtime"), systemImage: "books.vertical")
                }
                .accessibilityIdentifier("skillsNavigationLink")
                NavigationLink {
                    StickerGalleryView()
                } label: {
                    SettingsRowLabel(String(localized: "composer.stickers", table: "Composer"), systemImage: "face.smiling")
                }
                .accessibilityIdentifier("stickerGalleryNavigationLink")
            } header: {
                Text("settings.assistant", tableName: "Runtime")
                    .font(.caption)
                    .accessibilityIdentifier("settingsAssistantSectionHeader")
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
                        HStack(spacing: 8) {
                            Text(currentLanguage).foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    } label: {
                        SettingsRowLabel(String(localized: "settings.language", table: "Runtime"), systemImage: "globe")
                    }
                }
                .foregroundStyle(.primary)
                .disabled(model.isBusy)
                .accessibilityHint(String(localized: "settings.language_footer", table: "Runtime"))
                .accessibilityIdentifier("appLanguageSettingsButton")
                NavigationLink {
                    TaskSettingsView()
                } label: {
                    SettingsRowLabel(String(localized: "settings.taskStatus"), systemImage: "bell")
                }
                .accessibilityIdentifier("taskStatusSettingsButton")
                Toggle(isOn: $model.hapticsEnabled) {
                    SettingsRowLabel(String(localized: "settings.haptics", table: "Runtime"), systemImage: "hand.tap")
                }
                .tint(EiscueStyle.switchTint)
                .disabled(model.isBusy)
                .accessibilityIdentifier("hapticsToggle")
                Toggle(isOn: $model.disconnectAfterTask) {
                    SettingsRowLabel(String(localized: "settings.disconnectAfterTask", table: "Connections"), systemImage: "powerplug")
                }
                .tint(EiscueStyle.switchTint)
                .disabled(model.isBusy)
                .accessibilityIdentifier("disconnectAfterTaskToggle")
            } header: {
                Text("settings.section.general", tableName: "Runtime")
                    .font(.caption)
                    .accessibilityIdentifier("settingsGeneralSectionHeader")
            }
            .listRowBackground(EiscueStyle.surface)

            Section {
                NavigationLink {
                    ConnectionRepairView()
                } label: {
                    SettingsRowLabel(String(localized: "connectionRepair.title", table: "Connections"), systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("connectionRepairNavigationLink")
            } header: {
                Text("connectionRepair.settingsSection", tableName: "Connections")
                    .font(.caption)
                    .accessibilityIdentifier("settingsTroubleshootingSectionHeader")
            }
            .listRowBackground(EiscueStyle.surface)

            Section {
                NavigationLink { AboutView() } label: {
                    SettingsRowLabel(String(localized: "settings.about", table: "Runtime"), systemImage: "info.circle")
                }
                .accessibilityIdentifier("aboutNavigationLink")
            } header: {
                Text("settings.section.about", tableName: "Runtime")
                    .font(.caption)
                    .accessibilityIdentifier("settingsAboutSectionHeader")
            }
            .listRowBackground(EiscueStyle.surface)
            #if DEBUG
            Section {
                Toggle(isOn: $model.showsDebugTools) {
                    SettingsRowLabel(String(localized: "settings.debugTools", table: "Connections"), systemImage: "ladybug")
                }
                .tint(EiscueStyle.switchTint)
                .accessibilityIdentifier("debugToolsToggle")
            } header: {
                Text("settings.section.debug", tableName: "Runtime")
                    .font(.caption)
                    .accessibilityIdentifier("settingsDebugSectionHeader")
            }
            .listRowBackground(EiscueStyle.surface)
            #endif
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
                .tint(EiscueStyle.switchTint)
                .disabled(model.taskNotifications.isRequestingAuthorization)
                .accessibilityIdentifier("taskNotificationsToggle")
                if let error = model.taskNotifications.lastError {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.primary)
                }
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                } label: {
                    SettingsRowLabel(String(localized: "settings.notification_settings", table: "Runtime"), systemImage: "gearshape")
                }
            } header: {
                Text("settings.section.notifications", tableName: "Runtime")
                    .font(.caption)
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
            } header: {
                Text("settings.section.background", tableName: "Runtime")
                    .font(.caption)
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
