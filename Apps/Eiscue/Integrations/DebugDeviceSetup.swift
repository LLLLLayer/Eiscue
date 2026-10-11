#if DEBUG
import EiscueDeviceKit
import Foundation
import PhoneAgentNCM

extension AppModel {
    /// Explicit developer launch arguments only. Release builds have no automatic
    /// import or connection. Diagnostics never contain credentials or screen data.
    func runRequestedDeviceSetupCheck() async {
        let arguments = ProcessInfo.processInfo.arguments
        // This read-only mode takes precedence over every other debug action.
        // It never enters pairing, VPN, native service or owned-input setup.
        if arguments.contains("--wireless-board-probe") {
            guard !arguments.contains("--ui-testing"), !isBusy else { return }
            await runWirelessBoardProbe()
            return
        }
        // The wireless modifier also requires the existing owned-check gate so
        // its target view, lifecycle and opt-in input capabilities stay aligned.
        if arguments.contains("--owned-device-check-wireless"), !arguments.contains("--owned-device-check") {
            let report: [String: Any] = ["version": 3, "state": "failed", "phase": "configuration",
                "connectionMethod": DeviceConnectionMethod.wirelessBoard.rawValue,
                "reason": "owned_device_check_flag_required"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                try? data.write(to: URL.cachesDirectory.appendingPathComponent("EiscueOwnedDeviceCheck.json"), options: [.atomic, .completeFileProtection])
            }
            return
        }
        if arguments.contains("--owned-device-check"), !arguments.contains("--ui-testing"), !isBusy {
            await runOwnedDeviceCheck(method: arguments.contains("--owned-device-check-wireless") ? .wirelessBoard : .localVPN)
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

    /// Board diagnostics only: no identity access, authentication, capture or
    /// input. Copy only allowlisted protocol labels, never complete peer replies.
    private func runWirelessBoardProbe() async {
        let destination = URL.cachesDirectory.appendingPathComponent("EiscueWirelessBoardProbe.json")
        let client = NCMProbeClient(transport: .wifi)
        defer { client.cancel() }
        var report: [String: Any] = ["state": "started", "phase": "status", "transport": "wifi"]
        func save() throws {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".wireless-probe-\(UUID().uuidString).json")
            let files = FileManager.default
            guard files.createFile(atPath: temporary.path, contents: data,
                attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? files.removeItem(at: temporary) }
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else {
                try files.moveItem(at: temporary, to: destination)
            }
        }
        do {
            try save()
            let status = try await client.request(.status)
            report["statusLayer"] = status.layer
            report["statusResult"] = status.result
            for (key, command) in [("discoveryIPv6", DiagnosticCommand.discoverIPv6),
                                   ("discoveryIPv4", DiagnosticCommand.discoverIPv4)] {
                report["phase"] = key
                try save()
                let reply = try await client.request(command)
                var summary: [String: Any] = ["layer": reply.layer, "result": reply.result,
                    "endpoints": (reply.endpoints ?? []).map { endpoint -> [String: Any] in
                        ["service": endpoint.service, "family": endpoint.family]
                    }]
                if let osError = reply.osError { summary["osError"] = osError }
                report[key] = summary
                try save()
            }
            report["phase"] = "discovery"
            try save()
            let candidate = try await client.discoverRemotePairing()
            report["transport"] = candidate.transport.rawValue
            report["candidatePresent"] = true
            report["state"] = "finished"
            report["phase"] = "finished"
            try save()
        } catch {
            report["state"] = "failed"
            if let error = error as? NCMError {
                report["errorCategory"] = "NCMError"
                report["reason"] = error.rawValue
            } else if error is CancellationError {
                report["errorCategory"] = "CancellationError"
                report["reason"] = "cancelled"
            } else if error is NativeBackendError {
                report["errorCategory"] = "NativeBackendError"
                report["reason"] = "invalid_diagnostic_candidate"
            } else {
                report["errorCategory"] = "ProbeError"
                report["reason"] = "probe_or_report_failed"
            }
            try? save()
        }
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
