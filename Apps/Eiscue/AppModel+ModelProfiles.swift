import EiscueAgentKit
import Foundation

extension AppModel {
    var selectedModelProfile: ModelProfile? {
        modelProfiles.first { $0.id == selectedModelProfileID }
    }

    var canManageModelProfiles: Bool {
        !isLoading && !isBusy && !isSubmittingMessage && modelProfilesLoadError == nil
    }

    func hasAPIKey(for profileID: UUID) -> Bool {
        _ = modelCredentialRevision
        guard let profile = modelProfiles.first(where: { $0.id == profileID }),
              let key = try? credentials.read(profile.credentialAccount) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    func saveModelProfile(id: UUID? = nil, name: String, settings: ModelSettings, newKey: String) throws -> UUID {
        try requireModelProfileChanges()
        let previous = id.flatMap { value in modelProfiles.first { $0.id == value } }
        guard id == nil || previous != nil else { throw ModelProfilesError.notFound }
        let profile = ModelProfile(id: previous?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), settings: settings)
        let replacement = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only an existing profile can retain its own credential. Adding a new
        // endpoint must never inherit the currently selected provider's secret.
        let key = replacement.isEmpty ? (try previous.flatMap { try credentials.read($0.credentialAccount) } ?? "") : replacement
        let configuration = try settings.configuration(apiKey: key)
        var profiles = modelProfiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        let data = try JSONEncoder().encode(ModelProfileState(profiles: profiles, selectedID: profile.id))
        try credentials.write(key, account: profile.credentialAccount)
        modelCredentialRevision &+= 1
        persistModelProfiles(profiles, selectedID: profile.id, data: data)
        hasAPIKey = true
        configuredAgent = agentFactory(configuration, runtimeDirectory, [])
        agentAvailability = .ready
        return profile.id
    }

    func selectModelProfile(_ id: UUID) throws {
        try requireModelProfileChanges()
        guard let profile = modelProfiles.first(where: { $0.id == id }) else { throw ModelProfilesError.notFound }
        let key = try credentials.read(profile.credentialAccount)
        let configuration = key.flatMap { try? profile.settings.configuration(apiKey: $0) }
        let data = try JSONEncoder().encode(ModelProfileState(profiles: modelProfiles, selectedID: id))
        persistModelProfiles(modelProfiles, selectedID: id, data: data)
        hasAPIKey = key.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        configuredAgent = configuration.map { agentFactory($0, runtimeDirectory, []) }
            ?? agentFactory(nil, runtimeDirectory, [])
        agentAvailability = configuration == nil ? .unconfigured : .ready
    }

    func deleteModelProfile(_ id: UUID) throws {
        try requireModelProfileChanges()
        guard let profile = modelProfiles.first(where: { $0.id == id }) else { throw ModelProfilesError.notFound }
        let profiles = modelProfiles.filter { $0.id != id }
        let selection = selectedModelProfileID == id ? profiles.first?.id : selectedModelProfileID
        let data = try JSONEncoder().encode(ModelProfileState(profiles: profiles, selectedID: selection))
        try credentials.delete(profile.credentialAccount)
        modelCredentialRevision &+= 1
        persistModelProfiles(profiles, selectedID: selection, data: data)
        try refreshAgentConfiguration()
    }

    func removeAPIKey(for profileID: UUID) throws {
        try requireModelProfileChanges()
        guard let profile = modelProfiles.first(where: { $0.id == profileID }) else { throw ModelProfilesError.notFound }
        try credentials.delete(profile.credentialAccount)
        modelCredentialRevision &+= 1
        if profileID == selectedModelProfileID { try refreshAgentConfiguration() }
    }

    func saveModelSettings(_ settings: ModelSettings, newKey: String) throws {
        try saveModelProfile(id: selectedModelProfileID, name: selectedModelProfile?.name ?? "", settings: settings, newKey: newKey)
    }

    func removeAPIKey() {
        guard let id = selectedModelProfileID else { return }
        do { try removeAPIKey(for: id) }
        catch { errorMessage = error.localizedDescription }
    }

    func selectedModelAPIKey() throws -> String? {
        guard let profile = selectedModelProfile else { return nil }
        return try credentials.read(profile.credentialAccount)
    }

    func refreshAgentConfiguration() throws {
        // Clear the old provider before a Keychain failure can leave it usable
        // behind newly selected settings.
        configuredAgent = agentFactory(nil, runtimeDirectory, [])
        agentAvailability = .unconfigured
        hasAPIKey = false
        guard let key = try selectedModelAPIKey(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        hasAPIKey = true
        guard let configuration = try? modelSettings.configuration(apiKey: key) else { return }
        configuredAgent = agentFactory(configuration, runtimeDirectory, [])
        agentAvailability = .ready
    }

    var modelKeysForRedaction: [String] {
        let accounts = Set(modelProfiles.map(\.credentialAccount) + ["model-key"])
        let keys = accounts.compactMap { try? credentials.read($0) }
        return Set(keys.flatMap { [$0, $0.trimmingCharacters(in: .whitespacesAndNewlines)] })
            .filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    private func requireModelProfileChanges() throws {
        if modelProfilesLoadError != nil { throw ModelProfilesError.storageUnavailable }
        guard canManageModelProfiles else { throw ModelProfilesError.busy }
    }

    private func persistModelProfiles(_ profiles: [ModelProfile], selectedID: UUID?, data: Data) {
        // One preferences value commits the list and selection together; neither
        // this value nor the compatibility projection contains credentials.
        preferences.set(data, forKey: ModelProfileState.preferencesKey)
        modelProfiles = profiles
        selectedModelProfileID = selectedID
        modelSettings = selectedModelProfile?.settings ?? ModelSettings()
        if selectedID != nil, let settings = try? JSONEncoder().encode(modelSettings) {
            preferences.set(settings, forKey: "modelSettings")
        } else {
            preferences.removeObject(forKey: "modelSettings")
        }
    }
}
