import Darwin
import Foundation
import Testing
@testable import EiscueDeviceBackend

@Suite @MainActor struct LocalVPNReadinessTests {
    #if DEBUG
    @Test func diagnosticDistinguishesMissingAddressFromDownFlagsWithoutRecordingAddresses() {
        let absent = LocalVPNDiscovery.interfaceSnapshot([row(address: "10.8.1.1")], configuration: .defaults)
        let down = LocalVPNDiscovery.interfaceSnapshot([row(flags: UInt32(IFF_UP | IFF_POINTOPOINT))], configuration: .defaults)
        #expect(absent["matchingInterfaces"] == "0" && absent["utunIPv4Rows"] == "1")
        #expect(down["matchingInterfaces"] == "1" && down["running"] == "0" && down["up"] == "1")
        #expect(!absent.values.contains("10.8.1.1") && !down.values.contains("10.7.1.1"))
    }
    #endif
    @Test func waitsForOnlyTheConfiguredInterfaceToBecomeReady() async throws {
        let ready = row(), down = row(flags: UInt32(IFF_UP | IFF_POINTOPOINT))
        var elapsed = 0.0, reads = 0
        let selected = try await LocalVPNDiscovery.waitForInterface(configuration: .defaults, inventory: {
            reads += 1
            return reads == 1 ? [row(address: "10.8.1.1")] : (reads == 2 ? [down] : [ready])
        }, uptime: { elapsed }, pause: { elapsed += 0.05 })
        #expect(selected == ready)
        #expect(reads == 3 && elapsed == 0.1)
    }

    @Test func aPersistentlyMissingInterfaceStillFailsWithinTheBound() async {
        var elapsed = 0.0, reads = 0
        await #expect(throws: LocalVPNError.inactive) {
            _ = try await LocalVPNDiscovery.waitForInterface(configuration: .defaults, timeout: 0.1, inventory: {
                reads += 1; return []
            }, uptime: { elapsed }, pause: { elapsed += 0.05 })
        }
        #expect(elapsed == 0.1 && reads == 3)
    }

    @Test func ambiguityFailsImmediatelyWithoutWaitingOrSelectingAnotherRoute() async {
        var pauses = 0
        await #expect(throws: LocalVPNError.ambiguousInterface) {
            _ = try await LocalVPNDiscovery.waitForInterface(configuration: .defaults,
                inventory: { [row(), row(index: 8)] }, pause: { pauses += 1 })
        }
        #expect(pauses == 0)
    }

    @Test func inventoryFailureIsNotTreatedAsTransientReadiness() async {
        var pauses = 0
        await #expect(throws: NCMError.interfaceInvalid) {
            _ = try await LocalVPNDiscovery.waitForInterface(configuration: .defaults,
                inventory: { throw NCMError.interfaceInvalid }, pause: { pauses += 1 })
        }
        #expect(pauses == 0)
    }

    @Test func cancellationDuringReadinessDoesNotPublishAReadyInterface() async {
        var reads = 0
        let task = Task { @MainActor in
            try await LocalVPNDiscovery.waitForInterface(configuration: .defaults,
                inventory: { reads += 1; return [] }, pause: { try await Task.sleep(for: .seconds(30)) })
        }
        while reads == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(reads == 1)
    }

    private func row(index: UInt32 = 7, address: String = "10.7.1.1",
                     flags: UInt32 = UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT)) -> NCMInterfaceBinding.Row {
        .init(name: "utun-synthetic", index: index, address: address, mask: "255.255.255.0",
              flags: flags, linkType: UInt8(IFT_OTHER))
    }
}
