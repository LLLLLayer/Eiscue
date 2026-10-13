import Foundation
import Testing
@testable import EiscueDeviceKit

@Suite("Bluetooth decision age and stream liveness")
struct BluetoothFrameAuthorityTests {
    @Test func modelDecisionMayOutliveTheBroadcastPublicationWindow() {
        for delay in [3.29, 3.63, 4.09, 15, 29.99] {
            #expect(BluetoothFrameAuthority.permits(decisionIssuedUptime: 100 - delay,
                currentConfirmedUptime: 99.5, now: 100))
        }
    }

    @Test func liveBroadcastCannotRenewAnExpiredDecision() {
        for delay in [30.0, 31, 120] {
            #expect(!BluetoothFrameAuthority.permits(decisionIssuedUptime: 100 - delay,
                currentConfirmedUptime: 100, now: 100))
        }
    }

    @Test func decisionStillRequiresALiveBroadcastAndValidClocks() {
        #expect(!BluetoothFrameAuthority.permits(decisionIssuedUptime: 95,
            currentConfirmedUptime: 96.99, now: 100))
        #expect(BluetoothFrameAuthority.permits(decisionIssuedUptime: 95,
            currentConfirmedUptime: 97, now: 100))
        for invalid in [Double.nan, .infinity, -.infinity, 101] {
            #expect(!BluetoothFrameAuthority.permits(decisionIssuedUptime: invalid,
                currentConfirmedUptime: 99.5, now: 100))
            #expect(!BluetoothFrameAuthority.permits(decisionIssuedUptime: 95,
                currentConfirmedUptime: invalid, now: 100))
        }
    }
}
