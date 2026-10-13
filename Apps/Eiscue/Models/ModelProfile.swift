import Foundation

/// Persisted connection settings only. Credential accounts are derived from IDs,
/// never decoded from preferences or exposed to the editor.
struct ModelProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var settings: ModelSettings

    static let legacyID = UUID(uuidString: "E15C0E00-0000-4000-8000-000000000001")!

    var displayName: String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? settings.model : label
    }

    var credentialAccount: String {
        id == Self.legacyID ? "model-key" : "model-profile-\(id.uuidString)"
    }
}

struct ModelProfileState: Codable {
    static let preferencesKey = "modelProfiles"
    var version = 1
    var profiles: [ModelProfile]
    var selectedID: UUID?

    static func load(from preferences: UserDefaults) throws -> Self {
        if let value = preferences.object(forKey: preferencesKey) {
            guard let data = value as? Data else { throw ModelProfilesError.storageUnavailable }
            let state = try JSONDecoder().decode(Self.self, from: data)
            guard state.version == 1, Set(state.profiles.map(\.id)).count == state.profiles.count,
                  state.selectedID == nil || state.profiles.contains(where: { $0.id == state.selectedID }) else {
                throw ModelProfilesError.storageUnavailable
            }
            return state
        }
        guard let data = preferences.data(forKey: "modelSettings"),
              let settings = try? JSONDecoder().decode(ModelSettings.self, from: data),
              !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self(profiles: [], selectedID: nil)
        }
        // The legacy profile keeps the original Keychain account. Migration does
        // not need to read, copy or delete its secret and can safely run again.
        let profile = ModelProfile(id: ModelProfile.legacyID, name: "", settings: settings)
        let state = Self(profiles: [profile], selectedID: profile.id)
        preferences.set(try JSONEncoder().encode(state), forKey: preferencesKey)
        return state
    }
}

enum ModelProfilesError: LocalizedError {
    case busy, notFound, storageUnavailable

    var errorDescription: String? {
        switch self {
        case .busy: String(localized: "models.busy", table: "Models")
        case .notFound: String(localized: "models.notFound", table: "Models")
        case .storageUnavailable: String(localized: "models.storageUnavailable", table: "Models")
        }
    }
}
