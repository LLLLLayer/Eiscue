// Packet reflection design based on LocalDevVPN by Stossy11 / SideStore Team.
// Copyright (c) 2025 SideStore Team. Used under the StosVPN License.
// Reference fork: https://github.com/jkcoxson/LocalDevVPN
// Revision: af3fd697803ada4ac2b8d518358f5ab0a534844c
// See the bundled third-party license and attribution for LocalDevVPN.

import Darwin
import Foundation

/// Validates one complete IPv4 packet and reflects only our two local endpoints.
/// No packet content is retained or logged.
struct PacketReflector: Sendable {
    private let interfaceAddress: [UInt8]
    private let peerAddress: [UInt8]

    init() {
        // The shared configuration is fixed, rather than supplied by a caller.
        interfaceAddress = LocalTunnelConfiguration.interfaceAddress.split(separator: ".").compactMap { UInt8($0) }
        peerAddress = LocalTunnelConfiguration.peerAddress.split(separator: ".").compactMap { UInt8($0) }
    }

    func reflect(_ packet: Data, protocolFamily: Int32) -> Data? {
        guard protocolFamily == AF_INET, packet.count >= 20,
              interfaceAddress.count == 4, peerAddress.count == 4 else { return nil }

        let isValid = packet.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            guard bytes[0] >> 4 == 4 else { return false }
            let headerLength = Int(bytes[0] & 0x0F) * 4
            let totalLength = Int(bytes[2]) * 256 + Int(bytes[3])
            // A packetFlow item must contain exactly one complete IP packet.
            // Reject truncated packets, invalid options bounds and trailing data.
            guard headerLength >= 20, headerLength <= bytes.count,
                  totalLength >= headerLength, totalLength == bytes.count else { return false }

            let source = Array(bytes[12..<16])
            let destination = Array(bytes[16..<20])
            return (source == interfaceAddress && destination == peerAddress)
                || (source == peerAddress && destination == interfaceAddress)
        }
        guard isValid else { return nil }

        var reflected = packet
        reflected.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for offset in 0..<4 {
                let sourceByte = bytes[12 + offset]
                bytes[12 + offset] = bytes[16 + offset]
                bytes[16 + offset] = sourceByte
            }
        }
        // Swapping the addresses preserves the IPv4 checksum and the sum of the
        // TCP/UDP pseudo-header. Ports, options, fragments and payload stay intact.
        return reflected
    }
}
