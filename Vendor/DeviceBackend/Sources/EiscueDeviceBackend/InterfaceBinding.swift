// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from committed PA3 interface selection; no PA3/HID dependency.
import Foundation
import Network
import Darwin

/// The board link is chosen by the caller; it never falls back to another route.
public enum NCMBoardTransport: String, Sendable, Equatable {
    case usb
}

struct NCMInterfaceBinding {
    static let localIP = "192.168.7.2"
    static let remoteIP = "192.168.7.1"
    static let netmask = "255.255.255.0"
    struct Row: Equatable, Sendable {
        let name: String
        let index: UInt32
        let address: String
        let mask: String
        let flags: UInt32
        let linkType: UInt8?
    }
    let row: Row
    let interface: NWInterface
    let localAddress: IPv4Address
    let remoteAddress: IPv4Address
    let transport: NCMBoardTransport

    static func select(_ rows: [Row], transport: NCMBoardTransport = .usb) throws -> Row {
        var candidates: [Row] = []
        var hasAddress = false
        for row in rows where row.address == localIP {
            hasAddress = true
            if row.mask == netmask { candidates.append(row) }
        }
        guard hasAddress else { throw NCMError.interfaceUnavailable }
        guard candidates.count == 1 else { throw candidates.isEmpty ? NCMError.interfaceInvalid : .interfaceAmbiguous }
        let selected = candidates[0]
        let mustSet = [IFF_UP, IFF_RUNNING, IFF_BROADCAST].allSatisfy { selected.flags & UInt32($0) != 0 }
        let mustClear = [IFF_LOOPBACK, IFF_POINTOPOINT].allSatisfy { selected.flags & UInt32($0) == 0 }
        guard mustSet, mustClear, selected.index > 0, selected.linkType == UInt8(IFT_ETHER) else { throw NCMError.interfaceInvalid }
        return selected
    }
    static func validateType(_ type: NWInterface.InterfaceType, transport: NCMBoardTransport = .usb) throws {
        switch (transport, type) {
        case (.usb, .wiredEthernet), (.usb, .other): break // .other additionally requires IFT_ETHER and no POINTOPOINT above.
        default: throw NCMError.interfaceInvalid
        }
    }
    static func resolve(_ rows: [Row], transport: NCMBoardTransport = .usb) throws -> NCMInterfaceBinding {
        let row = try select(rows, transport: transport)
        // Compatibility workaround inherited from PA3: IPv4 %scope parsing is not
        // explicitly guaranteed by Apple documentation. Validate it and fail closed.
        // Validate the result; unsupported/stale scopes fail instead of unbinding.
        guard let remote = IPv4Address("\(remoteIP)%\(row.name)"),
              let local = IPv4Address("\(localIP)%\(row.name)"),
              let interface = remote.interface, local.interface == interface,
              interface.name == row.name, interface.index == Int(row.index) else {
            throw NCMError.interfaceInvalid
        }
        try validateType(interface.type, transport: transport)
        return NCMInterfaceBinding(row: row, interface: interface, localAddress: local, remoteAddress: remote, transport: transport)
    }
    func validateCurrent() throws {
        let current = try Self.resolve(Self.inventory(), transport: transport)
        guard current.row == row, current.interface == interface else { throw NCMError.interfaceInvalid }
    }
    func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localAddress), port: .any)
        parameters.includePeerToPeer = false
        return parameters
    }
    static func inventory() throws -> [Row] {
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) != 0 { throw NCMError.interfaceInvalid }
        defer { freeifaddrs(list) }
        var hardware: [String: UInt8] = [:]
        var rows: [Row] = []
        var next = list
        while let pointer = next {
            let record = pointer.pointee
            next = record.ifa_next
            let name = String(cString: record.ifa_name)
            guard let address = record.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                hardware[name] = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_dl.self).sdl_type
            case AF_INET:
                guard let ip = numericIPv4(address) else { continue }
                rows.append(Row(name: name, index: if_nametoindex(name), address: ip,
                                mask: numericIPv4(record.ifa_netmask) ?? "unknown", flags: record.ifa_flags, linkType: nil))
            default: break
            }
        }
        return rows.map { Row(name: $0.name, index: $0.index, address: $0.address, mask: $0.mask,
                              flags: $0.flags, linkType: hardware[$0.name]) }
    }
    private static func numericIPv4(_ address: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let address, Int32(address.pointee.sa_family) == AF_INET,
              Int(address.pointee.sa_len) >= MemoryLayout<sockaddr_in>.size else { return nil }
        var binary = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_in.self).sin_addr
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &binary, &output, socklen_t(output.count)) != nil else { return nil }
        return String(cString: output)
    }
}
