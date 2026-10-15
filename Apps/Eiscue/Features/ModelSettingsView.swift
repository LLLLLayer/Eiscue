import EiscueAgentKit
import SwiftUI

struct ModelSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ModelEditorDestination?
    @State private var pendingDeletion: ModelProfile?
    @State private var errorMessage: String?
    @State private var didOpen = false

    var body: some View {
        NavigationStack {
            List {
                if model.modelProfiles.isEmpty {
                    ContentUnavailableView(modelsText("models.empty"), systemImage: "sparkles",
                                           description: Text(modelsText("models.emptyDetail")))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(model.modelProfiles) { profile in
                            HStack(spacing: 12) {
                                Button { select(profile) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: model.selectedModelProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                                            .font(.title3).foregroundStyle(model.selectedModelProfileID == profile.id ? .primary : .tertiary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(profile.displayName).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                            Text(profile.displayName == profile.settings.model
                                                 ? (URL(string: profile.settings.baseURL)?.host ?? profile.settings.api.title)
                                                 : profile.settings.model)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            if !model.hasAPIKey(for: profile.id) {
                                                Text(modelsText("models.keyMissing")).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 4)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(profile.displayName)
                                .accessibilityHint(profile.settings.model)
                                .accessibilityIdentifier("selectModelProfile_\(profile.id.uuidString)")
                                .accessibilityValue(model.selectedModelProfileID == profile.id ? modelsText("models.selected") : "")
                                Button { editor = ModelEditorDestination(profile: profile) } label: {
                                    Image(systemName: "slider.horizontal.3").frame(width: 36, height: 36)
                                }
                                .buttonStyle(.glass).buttonBorderShape(.circle)
                                .accessibilityLabel(String(format: modelsText("models.editNamed"), profile.displayName))
                                .accessibilityIdentifier("editModelProfile_\(profile.id.uuidString)")
                            }
                            .padding(.vertical, 5)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDeletion = profile } label: {
                                    Label(modelsText("models.delete"), systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(modelsText("models.edit"), systemImage: "pencil") { editor = ModelEditorDestination(profile: profile) }
                                Button(modelsText("models.delete"), systemImage: "trash", role: .destructive) { pendingDeletion = profile }
                            }
                        }
                    }
                    .listRowBackground(EiscueStyle.surface)
                }
                Section {
                    Button { editor = ModelEditorDestination(profile: nil) } label: {
                        Label(modelsText("models.add"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("addModelProfileButton")
                }.listRowBackground(EiscueStyle.surface)
            }
            .disabled(!model.canManageModelProfiles)
            .listStyle(.insetGrouped).listSectionSpacing(.compact)
            .scrollContentBackground(.hidden).background(EiscueStyle.background)
            .navigationTitle(modelsText("models.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
            .navigationDestination(item: $editor) { destination in
                ModelProfileEditor(profile: destination.profile,
                                   cancel: { if model.modelProfiles.isEmpty { dismiss() } else { editor = nil } },
                                   saved: { editor = nil })
            }
            .onAppear {
                guard !didOpen else { return }
                didOpen = true
                if model.modelProfiles.isEmpty { editor = ModelEditorDestination(profile: nil) }
            }
            .confirmationDialog(modelsText("models.deleteTitle"), isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible, presenting: pendingDeletion) { profile in
                Button(modelsText("models.delete"), role: .destructive) {
                    do { try model.deleteModelProfile(profile.id) }
                    catch { errorMessage = model.safeError(error) }
                    pendingDeletion = nil
                }.accessibilityIdentifier("confirmDeleteModelProfileButton")
                Button("common.cancel", role: .cancel) { pendingDeletion = nil }
            } message: { _ in
                Text(modelsText("models.deleteDetail"))
            }
            .alert("model.unableToSave", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("common.ok", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func select(_ profile: ModelProfile) {
        do { try model.selectModelProfile(profile.id) }
        catch { errorMessage = model.safeError(error) }
    }
}

private struct ModelEditorDestination: Hashable {
    let id = UUID()
    let profile: ModelProfile?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct ModelProfileEditor: View {
    @Environment(AppModel.self) private var model
    let profile: ModelProfile?
    let cancel: () -> Void
    let saved: () -> Void
    @State private var settings: ModelSettings
    @State private var newKey = ""
    @State private var replacesKey = false
    @State private var errorMessage: String?
    @State private var confirmsKeyRemoval = false
    @State private var showsAdvanced = false
    @State private var outputTokens: String
    @State private var toolCalls: String
    @State private var timeoutSeconds: String
    @State private var validatesLimits = false
    @FocusState private var focusedLimit: ModelLimitField?

    init(profile: ModelProfile?, cancel: @escaping () -> Void, saved: @escaping () -> Void) {
        self.profile = profile; self.cancel = cancel; self.saved = saved
        let settings = profile?.settings ?? ModelSettings()
        _settings = State(initialValue: settings)
        _outputTokens = State(initialValue: String(settings.maxOutputTokens))
        _toolCalls = State(initialValue: String(settings.maxToolCalls))
        _timeoutSeconds = State(initialValue: String(settings.timeoutSeconds))
    }

    private var hasSavedKey: Bool { profile.map { model.hasAPIKey(for: $0.id) } ?? false }
    private var needsKeyEntry: Bool { !hasSavedKey || replacesKey }
    private var canSave: Bool {
        model.canManageModelProfiles
            && !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsKeyEntry || !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Form {
            Section {
                Picker("model.apiType", selection: $settings.api) {
                    ForEach(AgentAPI.allCases, id: \.self) { api in Text(api.title).tag(api) }
                }.accessibilityIdentifier("modelAPIType")
                clearableField(title: String(localized: "model.baseURL"), placeholder: String(localized: "model.baseURLPlaceholder"),
                               value: $settings.baseURL, identifier: "modelBaseURL", clearIdentifier: "clearModelBaseURLButton", keyboard: .URL)
                clearableField(title: String(localized: "model.identifier"), placeholder: String(localized: "model.identifierPlaceholder"),
                               value: $settings.model, identifier: "modelIdentifier", clearIdentifier: "clearModelIdentifierButton")
            } header: { Text("model.serviceSection") }
            .listRowBackground(EiscueStyle.surface)

            Section {
                if hasSavedKey {
                    HStack(spacing: 12) {
                        Label("model.keySaved", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(modelsText(replacesKey ? "models.cancelKeyChange" : "models.replaceKey")) {
                            newKey = ""; replacesKey.toggle()
                        }
                        .buttonStyle(.glass).controlSize(.small)
                        .accessibilityIdentifier("replaceAPIKeyButton")
                    }
                }
                if needsKeyEntry {
                    HStack(spacing: 8) {
                        SecureField("model.keyPlaceholder", text: $newKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive().accessibilityIdentifier("modelAPIKey")
                        clearButton($newKey, identifier: "clearModelAPIKeyButton")
                    }
                }
                if hasSavedKey && replacesKey {
                    Button("model.removeSavedKey", role: .destructive) { confirmsKeyRemoval = true }
                        .accessibilityIdentifier("removeAPIKeyButton")
                }
            } header: { Text("model.credentialsSection") }
              footer: { Text("model.credentialsDetail") }
            .listRowBackground(EiscueStyle.surface)

            Section {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    Toggle("model.supportsImages", isOn: $settings.supportsImages)
                        .tint(EiscueStyle.switchTint).accessibilityIdentifier("modelSupportsImages")
                    limitField(.outputTokens, value: $outputTokens)
                    limitField(.toolCalls, value: $toolCalls)
                    limitField(.timeout, value: $timeoutSeconds)
                } label: {
                    Text("model.advanced").accessibilityIdentifier("modelAdvancedOptions")
                }
            }.listRowBackground(EiscueStyle.surface)
        }
        .disabled(!model.canManageModelProfiles)
        .scrollContentBackground(.hidden).background(EiscueStyle.background)
        .navigationTitle(modelsText(profile == nil ? "models.add" : "models.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("common.cancel", action: cancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.done", action: save).disabled(!canSave).accessibilityIdentifier("saveModelSettingsButton")
            }
            ToolbarItemGroup(placement: .keyboard) {
                if focusedLimit != nil {
                    Spacer()
                    Button("common.done") { focusedLimit = nil }
                        .accessibilityIdentifier("modelLimitsKeyboardDoneButton")
                }
            }
        }
        .onChange(of: settings.api) { _, api in
            let defaults = ["https://api.openai.com/v1", "https://api.anthropic.com"]
            guard defaults.contains(settings.baseURL) else { return }
            settings.baseURL = api == .anthropicMessages ? "https://api.anthropic.com" : "https://api.openai.com/v1"
        }
        .onDisappear { newKey = "" }
        .alert("model.unableToSave", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("model.confirmRemoveKey", isPresented: $confirmsKeyRemoval, titleVisibility: .visible) {
            Button("model.removeKey", role: .destructive) {
                guard let profile else { return }
                do { try model.removeAPIKey(for: profile.id); newKey = ""; replacesKey = false }
                catch { errorMessage = model.safeError(error) }
            }
            Button("common.cancel", role: .cancel) { }
        } message: { Text("model.removeKeyDetail") }
    }

    private func clearableField(title: String, placeholder: String, value: Binding<String>, identifier: String,
                                clearIdentifier: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(placeholder, text: value).keyboardType(keyboard)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(identifier)
                clearButton(value, identifier: clearIdentifier)
            }
        }.padding(.vertical, 4)
    }

    private func clearButton(_ value: Binding<String>, identifier: String) -> some View {
        Button { value.wrappedValue = "" } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.tertiary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(value.wrappedValue.isEmpty)
        .opacity(value.wrappedValue.isEmpty ? 0 : 1)
        .accessibilityHidden(value.wrappedValue.isEmpty)
        .accessibilityLabel(modelsText("models.clear")).accessibilityIdentifier(identifier)
    }

    private func limitField(_ field: ModelLimitField, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(field.title)
                Spacer(minLength: 0)
                TextField(field.rangeLabel, text: value)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).monospacedDigit()
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .frame(minWidth: 72, maxWidth: 120).fixedSize(horizontal: false, vertical: true)
                    .focused($focusedLimit, equals: field)
                    .accessibilityLabel(field.title).accessibilityIdentifier(field.identifier)
                clearButton(value, identifier: "clear\(field.identifier)Button")
            }
            if validatesLimits, field.parse(value.wrappedValue) == nil {
                Text(String(format: modelsText("models.integerRange"), field.range.lowerBound.formatted(), field.range.upperBound.formatted()))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(field.identifier)Error")
            }
        }
    }

    private func save() {
        guard canSave else { return }
        validatesLimits = true
        for (field, value) in [(ModelLimitField.outputTokens, outputTokens), (.toolCalls, toolCalls), (.timeout, timeoutSeconds)] {
            if field.parse(value) == nil {
                showsAdvanced = true; focusedLimit = field
                return
            }
        }
        guard let outputTokens = ModelLimitField.outputTokens.parse(outputTokens),
              let toolCalls = ModelLimitField.toolCalls.parse(toolCalls),
              let timeoutSeconds = ModelLimitField.timeout.parse(timeoutSeconds) else { return }
        do {
            settings.maxOutputTokens = outputTokens; settings.maxToolCalls = toolCalls; settings.timeoutSeconds = timeoutSeconds
            settings.baseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try model.saveModelProfile(id: profile?.id, name: profile?.name ?? "", settings: settings,
                                          newKey: newKey.trimmingCharacters(in: .whitespacesAndNewlines))
            newKey = ""; saved()
        } catch {
            var message = model.safeError(error)
            for key in [newKey, newKey.trimmingCharacters(in: .whitespacesAndNewlines)] where !key.isEmpty {
                message = message.replacingOccurrences(of: key, with: String(localized: "model.redactedKey"))
            }
            errorMessage = message
        }
    }
}

private enum ModelLimitField: Hashable {
    case outputTokens, toolCalls, timeout

    var range: ClosedRange<Int> {
        switch self {
        case .outputTokens: 256...32_768
        case .toolCalls: 1...100
        case .timeout: 30...1_800
        }
    }
    var title: String {
        switch self {
        case .outputTokens: String(localized: "model.maxOutputTokens")
        case .toolCalls: String(localized: "model.maxToolCalls")
        case .timeout: modelsText("models.timeoutSeconds")
        }
    }
    var identifier: String {
        switch self {
        case .outputTokens: "maxOutputTokensInput"
        case .toolCalls: "maxToolCallsInput"
        case .timeout: "taskTimeoutInput"
        }
    }
    var rangeLabel: String { "\(range.lowerBound.formatted())–\(range.upperBound.formatted())" }

    func parse(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else { return nil }
        return value
    }
}

private func modelsText(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Models") }
