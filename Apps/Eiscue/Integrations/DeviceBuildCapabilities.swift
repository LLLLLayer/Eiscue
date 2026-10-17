import EiscueDeviceCore
#if !EISCUE_HID_ONLY
import EiscueDeviceKit
#endif

/// The distributable's capabilities, independent of runtime route preferences.
enum DeviceBuildCapabilities {
    #if EISCUE_HID_ONLY
    static let supportsDeveloperServices = false
    static let methods: [DeviceConnectionMethod] = [.bluetoothBoard]
    static let defaultMethod: DeviceConnectionMethod = .bluetoothBoard
    #else
    static let supportsDeveloperServices = true
    static let methods: [DeviceConnectionMethod] = [.localVPN, .bluetoothBoard, .usbBoard]
    static let defaultMethod: DeviceConnectionMethod = .localVPN
    #endif

    @MainActor static func makeClient() -> DeviceClient {
        #if EISCUE_HID_ONLY
        DeviceClient(controller: BluetoothDeviceController())
        #else
        DeviceClient()
        #endif
    }
}
