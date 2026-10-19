import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

final class PairingTransferTests: XCTestCase {
    func testOriginalV1JSONAndBinaryPlistFormatsRemainAcceptedWithoutAnEnvelope() throws {
        let record: [String: Any] = ["version": 1, "synthetic": "not a credential"]
        let json = try JSONSerialization.data(withJSONObject: record)
        let plist = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        for data in [json, plist] {
            XCTAssertNoThrow(try PairingTransfer.validateIdentitySchema(in: data))
        }
    }

    func testUnknownMissingAndInvalidVersionsGiveAFixedFormatError() throws {
        for record: [String: Any] in [["version": 2], ["version": true], ["version": "1"], [:]] {
            let data = try JSONSerialization.data(withJSONObject: record)
            XCTAssertThrowsError(try PairingTransfer.validateIdentitySchema(in: data)) { error in
                XCTAssertTrue(error is PairingTransfer.FormatError)
                XCTAssertEqual(error.localizedDescription,
                    String(localized: "pairing.transfer.unsupportedFormat", table: "Connections", bundle: Bundle(for: AppModel.self)))
            }
        }
    }

    @MainActor
    func testCopiedCommandDeclaresTheInstalledAppsAcceptedSchema() {
        XCTAssertTrue(ComputerPairingHelpView.command.contains("--app-pairing-schema \(PairingTransfer.supportedSchemaVersion)"))
    }

    @MainActor
    func testUnknownManualImportNeverReplacesTheSavedIdentity() async throws {
        let suite = "PairingTransferTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = URL.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageDirectory: directory, preferences: preferences,
                             credentialStore: CredentialStore(service: suite))
        let controller = PairingImportFixture()
        model.deviceClient = DeviceClient(actuator: controller, networkSetup: controller)
        model.isLoading = false
        model.hasPairingIdentity = true
        let file = directory.appendingPathComponent("unknown-format.json")
        try Data(#"{"version":2}"#.utf8).write(to: file)
        await model.importPairingIdentity(file)
        let calls = await controller.importCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(model.hasPairingIdentity)
        XCTAssertEqual(model.deviceConnectionError, PairingTransfer.FormatError.unsupported.localizedDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "A manually selected file remains user-owned.")
    }

    func testConsumesTransferWithoutKeepingTemporaryCredentialFile() throws {
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data("test fixture".utf8)
        try data.write(to: file)
        XCTAssertEqual(try PairingTransfer.readAndRemove(at: file), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRejectsOversizeAndSymbolicLinksWithoutReadingTheirTargets() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("link")
        try Data(repeating: 1, count: 32 * 1024 + 1).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try PairingTransfer.readAndRemove(at: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertThrowsError(try PairingTransfer.readAndRemove(at: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRejectedConsumedTransferIsStillRemoved() throws {
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(#"{"version":2}"#.utf8).write(to: file)
        var data = try PairingTransfer.readAndRemove(at: file)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        XCTAssertThrowsError(try PairingTransfer.validateIdentitySchema(in: data))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

private actor PairingImportFixture: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?
    var fixtureGeometry: DeviceFrameGeometry?
    var importCount = 0
    func status() async -> DeviceStatus { .unavailable(reason: "Synthetic disconnected route") }
    func hasPairingIdentity() async throws -> Bool { true }
    func importPairingIdentity(_ data: Data) async throws { importCount += 1 }
}
