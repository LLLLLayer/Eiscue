import NetworkExtension
import XCTest
@testable import Eiscue

@MainActor
final class LocalTunnelManagerTests: XCTestCase {
    private let providerID = "org.eiscue.test.tunnel"

    func testOwnershipUsesExactProviderIdentifierAndIgnoresDisplayName() throws {
        let unrelated = NETunnelProviderManager()
        LocalTunnelManager.configure(unrelated, providerID: "org.eiscue.test.tunnel.other")
        let owned = NETunnelProviderManager()
        LocalTunnelManager.configure(owned, providerID: providerID)
        owned.localizedDescription = "用户重命名后的通道"

        let selected = try LocalTunnelManager.ownedConfiguration(
            in: [unrelated, owned], providerID: providerID
        )

        XCTAssertTrue(selected === owned)
        XCTAssertNil(try LocalTunnelManager.ownedConfiguration(in: [unrelated], providerID: providerID))
    }

    func testDuplicateOwnedConfigurationsAreRejectedWithoutChangingEither() {
        let first = NETunnelProviderManager()
        let second = NETunnelProviderManager()
        LocalTunnelManager.configure(first, providerID: providerID)
        LocalTunnelManager.configure(second, providerID: providerID)

        XCTAssertThrowsError(try LocalTunnelManager.ownedConfiguration(
            in: [first, second], providerID: providerID
        )) { error in
            guard case LocalTunnelManager.Failure.duplicateConfigurations = error else {
                return XCTFail("Expected a duplicate-configuration error, got \(error)")
            }
        }
        XCTAssertTrue(first.isEnabled)
        XCTAssertTrue(second.isEnabled)
    }

    func testConfigurationDisablesOnDemandAndFullTunnelAndUsesFixedLocalPeer() throws {
        let manager = NETunnelProviderManager()
        manager.isOnDemandEnabled = true
        manager.onDemandRules = [NEOnDemandRuleConnect()]

        LocalTunnelManager.configure(manager, providerID: providerID)

        let configuration = try XCTUnwrap(manager.protocolConfiguration as? NETunnelProviderProtocol)
        XCTAssertEqual(configuration.providerBundleIdentifier, providerID)
        XCTAssertEqual(configuration.serverAddress, "10.7.0.1")
        XCTAssertEqual(configuration.providerConfiguration?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(configuration.providerConfiguration?["localAddress"] as? String, "10.7.1.1")
        XCTAssertEqual(configuration.providerConfiguration?["peerAddress"] as? String, "10.7.0.1")
        XCTAssertFalse(configuration.includeAllNetworks)
        XCTAssertFalse(configuration.enforceRoutes)
        XCTAssertFalse(manager.isOnDemandEnabled)
        XCTAssertTrue(manager.onDemandRules?.isEmpty ?? true)
        XCTAssertTrue(manager.isEnabled)
    }

    #if targetEnvironment(simulator)
    func testSimulatorStartExplicitlyFailsAndRefreshDoesNotCreateConfiguration() async throws {
        let manager = LocalTunnelManager()
        try await manager.refresh()
        XCTAssertFalse(manager.isConnected)
        XCTAssertFalse(manager.isTransitioning)
        do {
            try await manager.start()
            XCTFail("A simulator must not report a working local tunnel")
        } catch LocalTunnelManager.Failure.simulatorUnsupported {
            XCTAssertNotNil(manager.lastError)
        }
        XCTAssertFalse(manager.isConnected)
        XCTAssertFalse(manager.isTransitioning)
    }
    #endif
}
