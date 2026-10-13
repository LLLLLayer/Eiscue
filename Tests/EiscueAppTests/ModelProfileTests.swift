import EiscueAgentKit
import XCTest
@testable import Eiscue

@MainActor
final class ModelProfileTests: XCTestCase {
    func testLegacyMigrationPreservesKeyAndIsIdempotent() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings(model: "legacy-model")
        fixture.preferences.set(try JSONEncoder().encode(settings), forKey: "modelSettings")
        try fixture.credentials.write("legacy-test-secret", account: "model-key")

        let model = try fixture.makeModel()
        XCTAssertEqual(model.modelProfiles.count, 1)
        XCTAssertEqual(model.selectedModelProfileID, ModelProfile.legacyID)
        XCTAssertEqual(model.modelSettings, settings)
        XCTAssertTrue(model.hasAPIKey)
        XCTAssertEqual(try model.selectedModelAPIKey(), "legacy-test-secret")
        let reopened = try fixture.makeModel()
        XCTAssertEqual(reopened.modelProfiles, model.modelProfiles)
        XCTAssertEqual(try fixture.credentials.read("model-key"), "legacy-test-secret")
        let data = try XCTUnwrap(fixture.preferences.data(forKey: ModelProfileState.preferencesKey))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("legacy-test-secret"))
    }

    func testUnconfiguredInstallDoesNotCreateProfileOrDiscardOrphanedKey() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(try JSONEncoder().encode(ModelSettings()), forKey: "modelSettings")
        try fixture.credentials.write("orphaned-test-secret", account: "model-key")
        let model = try fixture.makeModel()
        XCTAssertTrue(model.modelProfiles.isEmpty)
        XCTAssertNil(model.selectedModelProfileID)
        XCTAssertFalse(model.hasAPIKey)
        XCTAssertNil(try model.selectedModelAPIKey())
        XCTAssertEqual(try fixture.credentials.read("model-key"), "orphaned-test-secret")
    }

    func testProfilesKeepIndependentKeysAndPersistSelection() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanUp() }
        let model = try fixture.makeModel()
        let first = try model.saveModelProfile(name: "First", settings: fixture.settings(model: "a"), newKey: "provider-a-test-secret")
        XCTAssertThrowsError(try model.saveModelProfile(name: "Second", settings: fixture.settings(model: "b"), newKey: ""))
        XCTAssertEqual(model.modelProfiles.count, 1)
        let second = try model.saveModelProfile(name: "Second", settings: fixture.settings(model: "b"), newKey: "provider-b-test-secret")
        try model.saveModelProfile(id: first, name: "Renamed", settings: fixture.settings(model: "a-new"), newKey: "")
        XCTAssertEqual(try model.selectedModelAPIKey(), "provider-a-test-secret")
        XCTAssertEqual(model.modelSettings.model, "a-new")
        try model.selectModelProfile(second)
        let reopened = try fixture.makeModel()
        XCTAssertEqual(reopened.selectedModelProfileID, second)
        XCTAssertEqual(reopened.modelSettings.model, "b")
        XCTAssertEqual(try reopened.selectedModelAPIKey(), "provider-b-test-secret")

        try reopened.removeAPIKey(for: first)
        XCTAssertFalse(reopened.hasAPIKey(for: first))
        XCTAssertTrue(reopened.hasAPIKey(for: second))
        XCTAssertTrue(reopened.hasAPIKey)
        let preferences = String(describing: fixture.preferences.dictionaryRepresentation())
        XCTAssertFalse(preferences.contains("provider-a-test-secret"))
        XCTAssertFalse(preferences.contains("provider-b-test-secret"))
    }

    func testDeletingLastProfileDoesNotResurrectLegacySettings() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(try JSONEncoder().encode(fixture.settings(model: "legacy")), forKey: "modelSettings")
        try fixture.credentials.write("legacy-test-secret", account: "model-key")
        let model = try fixture.makeModel()
        try model.deleteModelProfile(ModelProfile.legacyID)
        XCTAssertTrue(model.modelProfiles.isEmpty)
        XCTAssertNil(try fixture.credentials.read("model-key"))
        XCTAssertNil(fixture.preferences.data(forKey: "modelSettings"))
        let reopened = try fixture.makeModel()
        XCTAssertTrue(reopened.modelProfiles.isEmpty)
        XCTAssertNil(reopened.selectedModelProfileID)
        XCTAssertEqual(reopened.agentAvailability, .unconfigured)
    }

    func testModelChangesCannotRaceSubmissionOrSaving() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanUp() }
        let model = try fixture.makeModel()
        let first = try model.saveModelProfile(name: "First", settings: fixture.settings(model: "a"), newKey: "a-test-secret")
        let second = try model.saveModelProfile(name: "Second", settings: fixture.settings(model: "b"), newKey: "b-test-secret")
        model.isSubmittingMessage = true
        XCTAssertFalse(model.canManageModelProfiles)
        XCTAssertThrowsError(try model.selectModelProfile(first))
        model.isSubmittingMessage = false
        model.isSaving = true
        XCTAssertThrowsError(try model.deleteModelProfile(second))
        XCTAssertThrowsError(try model.saveModelSettings(fixture.settings(model: "changed"), newKey: "changed-test-secret"))
        XCTAssertEqual(model.selectedModelProfileID, second)
        XCTAssertEqual(try model.selectedModelAPIKey(), "b-test-secret")
        model.isSaving = false
    }

    func testErrorRedactionCoversAllSavedProfileKeys() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanUp() }
        let model = try fixture.makeModel()
        try model.saveModelProfile(name: "First", settings: fixture.settings(model: "a"), newKey: "first-test-secret")
        try model.saveModelProfile(name: "Second", settings: fixture.settings(model: "b"), newKey: "second-test-secret")
        let safe = model.safeError(AgentError.runtime("first-test-secret second-test-secret"))
        XCTAssertFalse(safe.contains("first-test-secret"))
        XCTAssertFalse(safe.contains("second-test-secret"))
    }

    func testDamagedProfileStorageCannotOverwriteExistingData() throws {
        let fixture = try ProfileFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(try JSONEncoder().encode(fixture.settings(model: "legacy")), forKey: "modelSettings")
        for malformed in [Data("not-profile-data".utf8) as NSObject, "wrong-storage-type" as NSString] {
            fixture.preferences.set(malformed, forKey: ModelProfileState.preferencesKey)
            let model = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences, credentialStore: fixture.credentials)
            model.isLoading = false
            XCTAssertFalse(model.canManageModelProfiles)
            XCTAssertThrowsError(try model.saveModelProfile(name: "New", settings: fixture.settings(model: "a"), newKey: "new-test-secret"))
            XCTAssertEqual(fixture.preferences.object(forKey: ModelProfileState.preferencesKey) as? NSObject, malformed)
        }
    }
}

@MainActor
private struct ProfileFixture {
    let suite: String
    let directory: URL
    let preferences: UserDefaults
    let credentials: CredentialStore

    init() throws {
        suite = "ModelProfileTests.\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        credentials = CredentialStore(service: suite)
    }

    func settings(model: String) -> ModelSettings {
        var settings = ModelSettings()
        settings.model = model
        return settings
    }

    func makeModel() throws -> AppModel {
        let model = AppModel(storageDirectory: directory, preferences: preferences, credentialStore: credentials)
        model.isLoading = false
        try model.refreshAgentConfiguration()
        return model
    }

    func cleanUp() {
        preferences.removePersistentDomain(forName: suite)
        try? credentials.deleteAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
