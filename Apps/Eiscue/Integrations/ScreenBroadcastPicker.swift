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
        // ReplayKit supplies a black icon on some OS versions even in dark
        // mode. Give the actual system control a consistent contrasting disc.
        picker.backgroundColor = .white
        picker.layer.cornerRadius = 26
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        picker.overrideUserInterfaceStyle = .light
        picker.tintColor = .black
    }
}
