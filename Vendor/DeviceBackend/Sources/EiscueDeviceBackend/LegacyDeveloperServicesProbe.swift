// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CEiscueDeviceBackend

extension NativeDeveloperServices {
    /// Explicit read-only compatibility probe on the current authenticated session.
    /// Call checkDeveloperReadiness() first. Requires existing-identity verification
    /// and screen authorization. Returns
    /// version-1 JSON with DTX handshake results, screenshot dimensions and numeric
    /// error categories only. Does not enable automation, authorize a process,
    /// launch a runner, perform input, save images or create a pairing identity.
    public func probeLegacyDeveloperServices() async throws -> Data {
        try await operation(UInt32(NCM_ACTION_LEGACY_DEVELOPER_PROBE))
    }
}
