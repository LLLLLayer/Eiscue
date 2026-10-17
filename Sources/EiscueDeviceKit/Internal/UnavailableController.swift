import EiscueDeviceCore
import Foundation

struct UnavailableController: DeviceController {
    func status() async -> DeviceStatus {
        .unavailable(reason: String(localized: "device.status.unavailable", defaultValue: "Device control is not set up.", bundle: EiscueDeviceResources.bundle))
    }
}
