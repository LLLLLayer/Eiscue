import Foundation
import Testing
@testable import EiscueDeviceCore

@Suite struct BluetoothBoardErrorTests {
    @Test(arguments: [BluetoothBoardError.authenticationKeyUnavailable, .enrollmentClosed, .enrollmentConflict])
    func setupPreservesAuthorizationDetailsWithoutChangingActionErrors(error: BluetoothBoardError) {
        #expect(error.connectionSetupError == .connection(error.localizedDescription))
        #expect(error.connectionSetupError.localizedDescription == error.localizedDescription)
        #expect(error.deviceControlError == .serviceUnavailable(.bluetooth))
    }

    @Test func setupKeepsTransportAndUnknownDeliveryClassifications() {
        for error in [BluetoothBoardError.deliveryUnknown, .gattWriteRejected, .malformedReply, .hidSendFailed] {
            #expect(error.connectionSetupError == .deliveryUnknown(""))
            #expect(error.connectionSetupError.isDeliveryUnknown)
        }
        #expect(BluetoothBoardError.authenticationFailed.connectionSetupError == .connectionLost)
        #expect(BluetoothBoardError.disconnected.connectionSetupError == .connectionLost)
        #expect(BluetoothBoardError.busy.connectionSetupError == .busy)
        #expect(BluetoothBoardError.commandTimeout.connectionSetupError == .serviceUnavailable(.bluetooth))
    }

    @Test(arguments: [
        ("en", "This app cannot read the board’s original control key. System Bluetooth pairing cannot restore that key. Use the app installation that still has the original key."),
        ("zh-Hans", "此 App 无法读取开发板原有的控制密钥。系统蓝牙配对无法恢复该密钥，请使用仍保存原控制密钥的 App 连接。")
    ])
    func missingControlKeyCopyDistinguishesSystemPairing(language: String, expected: String) throws {
        let resource = try #require(EiscueDeviceResources.bundle.url(forResource: "BluetoothBoard", withExtension: "strings",
            subdirectory: nil, localization: language))
        let bundle = try #require(Bundle(url: resource.deletingLastPathComponent()))
        let actual = NSLocalizedString("bluetooth.authentication-key-unavailable", tableName: "BluetoothBoard",
            bundle: bundle, value: "MISSING RESOURCE", comment: "")
        #expect(actual == expected)
    }
}
