import Foundation
import Testing
@testable import EiscueDeviceKit

@Suite("Bluetooth observation freshness")
struct BluetoothFrameAuthorityTests {
    @Test func newerBroadcastCannotRenewAnOldObservation() {
        let observed = UUID(), newer = UUID()
        #expect(!BluetoothFrameAuthority.permits(sourceFrameID: observed, capturedUptime: 85,
            currentSourceFrameID: newer, currentConfirmedUptime: 99.5, now: 100))
    }

    @Test func unchangedObservationNeedsItsOwnLiveHeartbeatOrRecentPublication() {
        let observed = UUID(), newer = UUID()
        #expect(BluetoothFrameAuthority.permits(sourceFrameID: observed, capturedUptime: 85,
            currentSourceFrameID: observed, currentConfirmedUptime: 99.5, now: 100))
        #expect(!BluetoothFrameAuthority.permits(sourceFrameID: observed, capturedUptime: 85,
            currentSourceFrameID: observed, currentConfirmedUptime: 96.9, now: 100))
        #expect(BluetoothFrameAuthority.permits(sourceFrameID: observed, capturedUptime: 98,
            currentSourceFrameID: newer, currentConfirmedUptime: 99.5, now: 100))
    }
}
