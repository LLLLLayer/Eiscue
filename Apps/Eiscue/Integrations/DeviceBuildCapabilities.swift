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

    @MainActor private static func makeHIDClient() -> DeviceClient {
        let controller = BluetoothDeviceController()
        return DeviceClient(actuator: controller, hidSetup: controller)
    }

    @MainActor static func makeClient() -> DeviceClient {
        #if EISCUE_HID_ONLY
        { let hid = BluetoothDeviceController(); return DeviceClient(actuator: hid, hidSetup: hid) }()
        #else
        DeviceClient()
        #endif
    }
}
