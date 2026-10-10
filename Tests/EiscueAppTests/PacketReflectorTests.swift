import Darwin
import Foundation
import XCTest

final class PacketReflectorTests: XCTestCase {
    private let reflector = PacketReflector()
    private let interface: [UInt8] = [10, 7, 1, 1]
    private let peer: [UInt8] = [10, 7, 0, 1]

    func testReflectsBothDirectionsWithoutChangingPortsOrPayload() throws {
        let outgoing = makeUDPPacket()
        let reflected = try XCTUnwrap(reflector.reflect(outgoing, protocolFamily: AF_INET))

        XCTAssertEqual(Array(reflected[12..<16]), peer)
        XCTAssertEqual(Array(reflected[16..<20]), interface)
        XCTAssertEqual(reflected.prefix(12), outgoing.prefix(12))
        XCTAssertEqual(reflected.dropFirst(20), outgoing.dropFirst(20))
        XCTAssertEqual(reflector.reflect(reflected, protocolFamily: AF_INET), outgoing)
    }

    func testAddressSwapPreservesIPv4AndUDPChecksumsIncludingOptions() throws {
        let original = makeUDPPacket(options: [1, 1, 1, 0])
        let reflected = try XCTUnwrap(reflector.reflect(original, protocolFamily: AF_INET))
        let headerLength = 24

        XCTAssertEqual(checksum(Array(original.prefix(headerLength))), 0)
        XCTAssertEqual(udpChecksum(original, headerLength: headerLength), 0)
        XCTAssertEqual(checksum(Array(reflected.prefix(headerLength))), 0)
        XCTAssertEqual(udpChecksum(reflected, headerLength: headerLength), 0)
        XCTAssertEqual(reflected[10..<12], original[10..<12])
        XCTAssertEqual(reflected[20..<24], original[20..<24], "IPv4 options must remain unchanged.")
        XCTAssertEqual(reflected[(headerLength + 6)..<(headerLength + 8)], original[(headerLength + 6)..<(headerLength + 8)])
    }

    func testDropsEveryTruncatedMinimumHeaderWithoutReadingOutOfBounds() {
        let valid = makeUDPPacket()
        for length in 0..<20 {
            XCTAssertNil(reflector.reflect(Data(valid.prefix(length)), protocolFamily: AF_INET), "Length \(length)")
        }
    }

    func testDropsIPv6UnsupportedFamiliesAndMismatchedVersion() {
        let packet = makeUDPPacket()
        for family in [AF_INET6, AF_UNSPEC, AF_UNIX] {
            XCTAssertNil(reflector.reflect(packet, protocolFamily: family))
        }
        for version in [UInt8(0), 1, 5, 6, 15] {
            var invalid = packet
            invalid[0] = (version << 4) | 5
            XCTAssertNil(reflector.reflect(invalid, protocolFamily: AF_INET))
        }
    }

    func testDropsInvalidHeaderLengthsAndUnboundedOptions() {
        let packet = makeUDPPacket()
        for ihl in [UInt8(0), 1, 4, 9, 15] {
            var invalid = packet
            invalid[0] = 0x40 | ihl
            XCTAssertNil(reflector.reflect(invalid, protocolFamily: AF_INET), "IHL \(ihl)")
        }

        var totalShorterThanHeader = makeUDPPacket(options: [1, 1, 1, 0])
        totalShorterThanHeader[3] = 20
        XCTAssertNil(reflector.reflect(totalShorterThanHeader, protocolFamily: AF_INET))
    }

    func testDropsTruncatedPayloadTrailingDataAndInvalidTotalLength() {
        let packet = makeUDPPacket()
        XCTAssertNil(reflector.reflect(Data(packet.dropLast()), protocolFamily: AF_INET))
        XCTAssertNil(reflector.reflect(packet + Data([0]), protocolFamily: AF_INET))
        for length in [0, 19, packet.count - 1, packet.count + 1, 65_535] {
            var invalid = packet
            invalid[2] = UInt8(length >> 8)
            invalid[3] = UInt8(length & 0xFF)
            XCTAssertNil(reflector.reflect(invalid, protocolFamily: AF_INET), "Total length \(length)")
        }
    }

    func testDropsPacketsOutsideTheExactConfiguredAddressPair() {
        let other: [UInt8] = [10, 7, 1, 2]
        let internet: [UInt8] = [1, 1, 1, 1]
        let multicast: [UInt8] = [224, 0, 0, 1]
        let cases: [([UInt8], [UInt8])] = [
            (interface, interface), (peer, peer), (other, peer), (interface, other),
            (internet, peer), (interface, internet), (interface, multicast)
        ]
        for (source, destination) in cases {
            var packet = makeUDPPacket()
            packet.replaceSubrange(12..<16, with: source)
            packet.replaceSubrange(16..<20, with: destination)
            XCTAssertNil(reflector.reflect(packet, protocolFamily: AF_INET))
        }
    }

    func testHandlesDataSlicesAndDoesNotMutateTheOriginalStorage() throws {
        let original = makeUDPPacket()
        let storage = Data([0xAA, 0xBB, 0xCC]) + original
        let slice = storage.dropFirst(3)
        let reflected = try XCTUnwrap(reflector.reflect(slice, protocolFamily: AF_INET))

        XCTAssertEqual(reflector.reflect(reflected, protocolFamily: AF_INET), original)
        XCTAssertEqual(storage, Data([0xAA, 0xBB, 0xCC]) + original)
    }

    func testPreservesFragmentMetadataAndAcceptsMaximumIPv4PacketSize() throws {
        var packet = makeUDPPacket()
        packet[6] = 0x20 // More Fragments flag.
        packet[7] = 0x10 // Non-zero fragment offset.
        let reflectedFragment = try XCTUnwrap(reflector.reflect(packet, protocolFamily: AF_INET))
        XCTAssertEqual(reflectedFragment[4..<12], packet[4..<12])
        XCTAssertEqual(reflectedFragment.dropFirst(20), packet.dropFirst(20))

        packet.append(Data(repeating: 0xA5, count: 65_535 - packet.count))
        packet[2] = 0xFF
        packet[3] = 0xFF
        let reflectedMaximum = try XCTUnwrap(reflector.reflect(packet, protocolFamily: AF_INET))
        XCTAssertEqual(reflectedMaximum.count, 65_535)
        XCTAssertEqual(reflectedMaximum.dropFirst(20), packet.dropFirst(20))
    }

    private func makeUDPPacket(options: [UInt8] = []) -> Data {
        let body: [UInt8] = [0xC0, 0x00, 0x12, 0x34, 0, 12, 0, 0, 1, 2, 3, 4]
        let headerLength = 20 + options.count
        let totalLength = headerLength + body.count
        var bytes: [UInt8] = [UInt8(0x40 + headerLength / 4), 0, UInt8(totalLength >> 8), UInt8(totalLength & 0xFF),
                             0x12, 0x34, 0x40, 0, 64, 17, 0, 0]
        bytes += interface + peer + options + body
        let ipChecksum = checksum(Array(bytes.prefix(headerLength)))
        bytes[10] = UInt8(ipChecksum >> 8)
        bytes[11] = UInt8(ipChecksum & 0xFF)
        let udpChecksum = udpChecksum(Data(bytes), headerLength: headerLength)
        bytes[headerLength + 6] = UInt8(udpChecksum >> 8)
        bytes[headerLength + 7] = UInt8(udpChecksum & 0xFF)
        return Data(bytes)
    }

    private func udpChecksum(_ packet: Data, headerLength: Int) -> UInt16 {
        let body = Array(packet.dropFirst(headerLength))
        let pseudoHeader = Array(packet[12..<20]) + [0, 17, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
        return checksum(pseudoHeader + body)
    }

    private func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[offset]) << 8
            if offset + 1 < bytes.count { sum += UInt32(bytes[offset + 1]) }
        }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
