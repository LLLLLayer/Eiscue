// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from committed PA3 interface selection; no PA3/HID dependency.
import Foundation
import Network
import Darwin

struct NCMInterfaceBinding {
    static let localIP = "192.168.7.2"
    static let remoteIP = "192.168.7.1"
    static let netmask = "255.255.255.0"
    struct Row: Equatable {
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

    static func select(_ rows: [Row]) throws -> Row {
        let matches = rows.filter { $0.address == localIP }
        guard matches.count == 1, let row = matches.first else {
            throw matches.isEmpty ? NCMError.interfaceUnavailable : NCMError.interfaceAmbiguous
        }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let forbidden = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        guard row.index > 0, row.mask == netmask, row.flags & required == required,
              row.flags & forbidden == 0, row.linkType == UInt8(IFT_ETHER) else {
            throw NCMError.interfaceInvalid
        }
        return row
    }
    static func validateType(_ type: NWInterface.InterfaceType) throws {
        switch type {
        case .wiredEthernet, .other: break // .other additionally requires IFT_ETHER and no POINTOPOINT above.
        default: throw NCMError.interfaceInvalid
        }
    }
    static func resolve(_ rows: [Row]) throws -> NCMInterfaceBinding {
        let row = try select(rows)
        // Compatibility workaround inherited from PA3: IPv4 %scope parsing is not
        // explicitly guaranteed by Apple documentation. Validate it and fail closed.
        // Validate the result; unsupported/stale scopes fail instead of unbinding.
        guard let remote = IPv4Address("\(remoteIP)%\(row.name)"),
              let local = IPv4Address("\(localIP)%\(row.name)"),
              let interface = remote.interface, local.interface == interface,
              interface.name == row.name, interface.index == Int(row.index) else {
            throw NCMError.interfaceInvalid
        }
        try validateType(interface.type)
        return NCMInterfaceBinding(row: row, interface: interface, localAddress: local, remoteAddress: remote)
    }
    func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localAddress), port: .any)
        parameters.includePeerToPeer = false
        return parameters
    }
    static func inventory() throws -> [Row] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw NCMError.interfaceInvalid }
        defer { freeifaddrs(head) }
        var entries: [(String, String, String, UInt32)] = []
        var linkTypes: [String: UInt8] = [:]
        var cursor = head
        func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
            guard let pointer, pointer.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointer, socklen_t(pointer.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee, name = String(cString: value.ifa_name)
            if let address = ipv4(value.ifa_addr) {
                entries.append((name, address, ipv4(value.ifa_netmask) ?? "unknown", value.ifa_flags))
            }
            if let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) {
                // Read the link type only, never link-layer addresses (MACs).
                linkTypes[name] = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee.sdl_type
            }
        }
        return entries.map { name, address, mask, flags in
            Row(name: name, index: if_nametoindex(name), address: address, mask: mask, flags: flags, linkType: linkTypes[name])
        }
    }
}
