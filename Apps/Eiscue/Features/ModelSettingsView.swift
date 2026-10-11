import EiscueAgentKit
import SwiftUI

struct ModelSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ModelSettings()
    @State private var newKey = ""
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var confirmsKeyRemoval = false
    @State private var showsAdvanced = false

    private var canSave: Bool {
        !model.isBusy
            && !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (model.hasAPIKey || !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("model.apiType", selection: $settings.api) {
                        ForEach(AgentAPI.allCases, id: \.self) { api in
                            Text(api.title).tag(api)
                        }
                    }
                    .accessibilityIdentifier("modelAPIType")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("model.baseURL").font(.subheadline)
                        TextField("model.baseURLPlaceholder", text: $settings.baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("modelBaseURL")
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("model.identifier").font(.subheadline)
                        TextField("model.identifierPlaceholder", text: $settings.model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("modelIdentifier")
                    }
                    .padding(.vertical, 4)

                } header: {
                    Text("model.serviceSection")
                }

                Section {
                    if model.hasAPIKey {
                        Label("model.keySaved", systemImage: "checkmark.shield")
                            .foregroundStyle(.secondary)
                    }
                    SecureField(model.hasAPIKey ? String(localized: "model.retainKeyPlaceholder") : String(localized: "model.keyPlaceholder"), text: $newKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityIdentifier("modelAPIKey")
                    if model.hasAPIKey {
                        Button("model.removeSavedKey", role: .destructive) {
                            confirmsKeyRemoval = true
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("removeAPIKeyButton")
                    }
                } header: {
                    Text("model.credentialsSection")
                } footer: {
                    Text("model.credentialsDetail")
                }

                Section {
                    DisclosureGroup(isExpanded: $showsAdvanced) {
                        Toggle("model.supportsImages", isOn: $settings.supportsImages)
                            .accessibilityIdentifier("modelSupportsImages")
                        Stepper(value: $settings.maxOutputTokens, in: 256...32_768, step: 256) {
                            LabeledContent("model.maxOutputTokens", value: settings.maxOutputTokens.formatted())
                        }
                        .accessibilityIdentifier("maxOutputTokensStepper")
                        Stepper(value: $settings.maxToolCalls, in: 1...100) {
                            LabeledContent("model.maxToolCalls", value: String(localized: "model.toolCallCount \(settings.maxToolCalls)"))
                        }
                        .accessibilityIdentifier("maxToolCallsStepper")
                        Stepper(value: $settings.timeoutSeconds, in: 30...1_800, step: 30) {
                            LabeledContent("model.taskTimeout", value: durationLabel)
                        }
                        .accessibilityIdentifier("taskTimeoutStepper")
                        Text(endpointHint).font(.caption).foregroundStyle(.secondary)
                        Text("model.serviceRequirements").font(.caption).foregroundStyle(.secondary)
                        Text("model.limitsDetail").font(.caption).foregroundStyle(.secondary)
                    } label: {
                        Text("model.advanced")
                            .accessibilityIdentifier("modelAdvancedOptions")
                    }
                }
            }
            .disabled(model.isBusy)
            .scrollContentBackground(.hidden)
            .background(EiscueStyle.background)
            .navigationTitle("model.settingsTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier("saveModelSettingsButton")
                }
            }
            .onAppear {
                guard !didLoad else { return }
                settings = model.modelSettings
                didLoad = true
            }
            .onChange(of: settings.api) { _, api in
                let defaults = ["https://api.openai.com/v1", "https://api.anthropic.com"]
                guard defaults.contains(settings.baseURL) else { return }
                settings.baseURL = api == .anthropicMessages
                    ? "https://api.anthropic.com" : "https://api.openai.com/v1"
            }
            .alert("model.unableToSave", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("common.ok", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("model.confirmRemoveKey", isPresented: $confirmsKeyRemoval, titleVisibility: .visible) {
                Button("model.removeKey", role: .destructive) {
                    guard !model.isBusy else { return }
                    model.removeAPIKey()
                    if !model.hasAPIKey {
                        newKey = ""
                        dismiss()
                    }
                }
                Button("common.cancel", role: .cancel) { }
            } message: {
                Text("model.removeKeyDetail")
            }
        }
    }

    private var durationLabel: String {
        Duration.seconds(settings.timeoutSeconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }

    private var endpointHint: String {
        switch settings.api {
        case .anthropicMessages:
            String(localized: "model.anthropicEndpointHint")
        case .openAICompletions:
            String(localized: "model.completionsEndpointHint")
        case .openAIResponses:
            String(localized: "model.responsesEndpointHint")
        }
    }

    private func save() {
        guard !model.isBusy else { return }
        do {
            settings.baseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            try model.saveModelSettings(settings, newKey: newKey.trimmingCharacters(in: .whitespacesAndNewlines))
            newKey = ""
            dismiss()
        } catch {
            let message = model.safeError(error)
            errorMessage = newKey.isEmpty ? message : message.replacingOccurrences(of: newKey, with: String(localized: "model.redactedKey"))
        }
    }
}
