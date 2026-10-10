#if DEBUG
import EiscueDeviceKit
import Foundation

extension AppModel {
    /// Explicit developer launch arguments only. Release builds have no automatic
    /// import or connection. Diagnostics never contain credentials or screen data.
    func runRequestedDeviceSetupCheck() async {
        let arguments = ProcessInfo.processInfo.arguments
        let imports = arguments.contains("--import-pairing-transfer")
        let checks = arguments.contains("--device-connection-check")
        guard imports || checks, !arguments.contains("--ui-testing"), !isBusy else { return }
        var report = ["state": "started", "phase": "import"]
        func writeReport() {
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
            try? data.write(to: URL.cachesDirectory.appendingPathComponent("EiscueDeviceCheck.json"), options: .atomic)
        }
        writeReport()
        if imports {
            // Developer automation never replaces an existing identity silently.
            guard !hasPairingIdentity else {
                report["state"] = "failed"; report["reason"] = "identity_already_exists"
                writeReport(); return
            }
            await importTransferredPairingIdentity()
            guard hasPairingIdentity else {
                report["state"] = "failed"; report["reason"] = "identity_import_failed"
                writeReport(); return
            }
        }
        report["identitySaved"] = String(hasPairingIdentity)
        if checks {
            guard localTunnel.isConnected else {
                report["state"] = "failed"; report["reason"] = "local_tunnel_not_connected"
                writeReport(); return
            }
            report["phase"] = "connect"; writeReport()
            await connectDevice()
            guard isDeviceReady else {
                report["state"] = "failed"; report["reason"] = "device_connection_failed"
                report["detail"] = connectionMessage
                writeReport(); return
            }
            report["phase"] = "screenshot"; writeReport()
            await previewScreenshot()
            if let screenshot {
                report["width"] = String(screenshot.width)
                report["height"] = String(screenshot.height)
                report["state"] = "passed"
            } else {
                report["state"] = "failed"; report["reason"] = "screenshot_failed"
                report["detail"] = connectionMessage
            }
            await disconnectDevice()
        } else { report["state"] = "passed" }
        report["phase"] = "finished"; writeReport()
    }
}
#endif
