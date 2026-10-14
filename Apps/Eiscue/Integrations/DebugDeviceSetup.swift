#if DEBUG
import EiscueDeviceKit
import Foundation

extension AppModel {
    /// Explicit developer launch arguments only. Release builds have no automatic
    /// import or connection. Diagnostics never contain credentials or screen data.
    func runRequestedDeviceSetupCheck() async {
        let arguments = ProcessInfo.processInfo.arguments
        // Retired route flags must not turn an old diagnostic command into a
        // local-VPN check or allow another setup action to run instead.
        guard !arguments.contains("--wireless-board-probe"),
              !arguments.contains("--owned-device-check-wireless") else { return }
        // The BLE fixture owns its own transport and diagnostics. Never start
        // any network/XCTest device path alongside this independent check.
        if arguments.contains("--ble-device-check") { return }
        if arguments.contains("--owned-device-check"), !arguments.contains("--ui-testing"), !isBusy {
            await runOwnedDeviceCheck()
            return
        }
        if arguments.contains("--legacy-device-probe"), !arguments.contains("--ui-testing"), !isBusy {
            await runLegacyDeviceProbe()
            return
        }
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

    /// Read-only iOS 26 compatibility check, opt-in through a developer launch
    /// argument. Saved diagnostics contain dimensions/stages, never pixels/keys.
    private func runLegacyDeviceProbe() async {
        let destination = URL.cachesDirectory.appendingPathComponent("EiscueLegacyProbe.json")
        var report: [String: Any] = ["state": "started", "phase": "connection", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString]
        func save() {
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
            try? data.write(to: destination, options: [.atomic, .completeFileProtection])
        }
        save()
        if !localTunnel.isConnected, ProcessInfo.processInfo.arguments.contains("--resume-existing-local-tunnel") {
            do { try await localTunnel.resumeExistingForDiagnostics() }
            catch { report["state"] = "failed"; report["reason"] = error.localizedDescription; save(); return }
        }
        guard localTunnel.isConnected else {
            report["state"] = "failed"; report["reason"] = "local_tunnel_not_connected"; save(); return
        }
        do {
            let result = try await deviceClient.probeLegacyDeveloperServices()
            report["probe"] = try JSONSerialization.jsonObject(with: result)
            report["state"] = "finished"
        } catch {
            report["state"] = "failed"
            report["reason"] = error.localizedDescription
        }
        report["phase"] = "finished"
        save()
    }
}
#endif
