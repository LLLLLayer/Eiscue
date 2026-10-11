import EiscueDeviceKit
import Foundation

/// A trusted desktop can send this one temporary file through the app's USB
/// container service. No other app's pairing records or directories are scanned.
enum PairingTransfer {
    static var url: URL { URL.temporaryDirectory.appendingPathComponent("EiscuePairingTransfer.json") }

    static func readAndRemove(at url: URL) throws -> Data {
        defer { try? FileManager.default.removeItem(at: url) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 32 * 1024 else {
            throw DeviceControlError.invalidIdentity
        }
        return try Data(contentsOf: url)
    }
}

extension AppModel {
    func refreshPairingTransfer() {
        hasTransferredPairingIdentity = FileManager.default.fileExists(atPath: PairingTransfer.url.path)
    }

    func importTransferredPairingIdentity() async {
        guard !isBusy else { return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true
        defer {
            if deviceOperationID == operationID { isConnecting = false }
            refreshPairingTransfer()
        }
        do {
            var data = try PairingTransfer.readAndRemove(at: PairingTransfer.url)
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            try await deviceClient.importPairingIdentity(data)
            guard deviceOperationID == operationID else { return }
            deviceConnectionError = nil
            connectionMessage = String(localized: "connection.identityImported")
            await refreshDeviceStatus()
        } catch {
            if deviceOperationID == operationID {
                deviceConnectionError = error.localizedDescription
                connectionMessage = error.localizedDescription
            }
        }
    }
}
