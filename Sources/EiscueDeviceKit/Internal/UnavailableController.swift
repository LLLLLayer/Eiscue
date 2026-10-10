import Foundation

struct UnavailableController: DeviceController {
    func status() async -> DeviceStatus {
        .unavailable(reason: String(localized: "device.status.unavailable", defaultValue: "Device control has not been configured.", bundle: .module))
    }
}
