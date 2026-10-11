import EiscueDeviceKit
import ReplayKit
import SwiftUI

/// A real system button: the user must tap it and confirm iOS's broadcast sheet.
/// Never synthesize button actions or programmatically bypass that confirmation.
struct ScreenBroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        picker.preferredExtension = ScreenBroadcastStore.broadcastExtensionBundleIdentifier
        picker.showsMicrophoneButton = false
        picker.tintColor = .label
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        picker.tintColor = .label
    }
}
