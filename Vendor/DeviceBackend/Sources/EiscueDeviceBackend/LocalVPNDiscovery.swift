// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public enum LocalVPNError: Error, Equatable {
    case inactive, ambiguousInterface, serviceNotFound, ambiguousService, discoveryDenied, invalidConfiguration
}

/// Addresses belong to the externally configured packet-reflection VPN.
public struct VPNLoopbackConfiguration: Equatable, Sendable {
    public let localAddress: String
    public let peerAddress: String
    let localIPv4: UInt32
    let peerIPv4: UInt32
    public static let defaults = try! Self(localAddress: "10.7.1.1", peerAddress: "10.7.0.1")
    public init(localAddress: String, peerAddress: String) throws {
        func parse(_ text: String) throws -> (String, UInt32) {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var binary = in_addr()
            guard !normalized.utf8.contains(0), normalized.withCString({ inet_pton(AF_INET, $0, &binary) }) == 1 else { throw LocalVPNError.invalidConfiguration }
            var canonical = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &binary, &canonical, socklen_t(canonical.count)) != nil,
                  String(cString: canonical) == normalized else { throw LocalVPNError.invalidConfiguration }
            let value = UInt32(bigEndian: binary.s_addr)
            switch value >> 24 {
            case 0, 127, 224...255: throw LocalVPNError.invalidConfiguration
            default: return (normalized, value)
            }
        }
        let local = try parse(localAddress), peer = try parse(peerAddress)
        guard local.1 != peer.1 else { throw LocalVPNError.invalidConfiguration }
        self.localAddress = local.0; self.peerAddress = peer.0
        self.localIPv4 = local.1; self.peerIPv4 = peer.1
    }
}

/// Discovery identifies this phone by its own addresses; authentication still pins
/// the stored peer key. A nearby phone's Bonjour port is never a candidate.
@MainActor public final class LocalVPNDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private final class Search {
        let id = UUID()
        let browser = NetServiceBrowser()
        var pending: CheckedContinuation<UInt16, Error>?
        var deadline: Task<Void, Never>?
        var candidates: [String: NetService] = [:]
        var resolved: [String: UInt16] = [:]
        func stop() {
            deadline?.cancel()
            browser.delegate = nil
            browser.stop()
            for service in candidates.values { service.delegate = nil; service.stop() }
        }
    }
    private var active: Search?
    #if DEBUG
    public private(set) var interfaceDiagnostic: [String: String] = [:]
    #endif
    public override init() { super.init() }

    static func selectInterface(_ rows: [NCMInterfaceBinding.Row], configuration: VPNLoopbackConfiguration = .defaults) throws -> NCMInterfaceBinding.Row {
        var selected: NCMInterfaceBinding.Row?
        for row in rows where row.name.hasPrefix("utun") && row.address == configuration.localAddress {
            guard selected == nil else { throw LocalVPNError.ambiguousInterface }
            selected = row
        }
        guard let link = selected else { throw LocalVPNError.inactive }
        let up = link.flags & UInt32(IFF_UP) != 0
        let running = link.flags & UInt32(IFF_RUNNING) != 0
        let pointToPoint = link.flags & UInt32(IFF_POINTOPOINT) != 0
        let loopback = link.flags & UInt32(IFF_LOOPBACK) != 0
        guard link.index != 0, up, running, pointToPoint, !loopback else { throw LocalVPNError.inactive }
        return link
    }
    static func selectPort(_ ports: [UInt16]) throws -> UInt16 {
        var selected: UInt16?
        for port in ports where port != 0 {
            if let selected, selected != port { throw LocalVPNError.ambiguousService }
            selected = port
        }
        guard let selected else { throw LocalVPNError.serviceNotFound }
        return selected
    }
    #if DEBUG
    static func interfaceSnapshot(_ rows: [NCMInterfaceBinding.Row], configuration: VPNLoopbackConfiguration) -> [String: String] {
        let matches = rows.filter { $0.name.hasPrefix("utun") && $0.address == configuration.localAddress }
        var result = ["uptimeMilliseconds": String(UInt64(ProcessInfo.processInfo.systemUptime * 1000)),
                      "ipv4Rows": String(rows.count), "utunIPv4Rows": String(rows.filter { $0.name.hasPrefix("utun") }.count),
                      "matchingInterfaces": String(matches.count)]
        if matches.count == 1, let row = matches.first {
            result["interfaceIndex"] = String(row.index); result["flags"] = String(row.flags)
            result["up"] = row.flags & UInt32(IFF_UP) != 0 ? "1" : "0"
            result["running"] = row.flags & UInt32(IFF_RUNNING) != 0 ? "1" : "0"
            result["pointToPoint"] = row.flags & UInt32(IFF_POINTOPOINT) != 0 ? "1" : "0"
            result["loopback"] = row.flags & UInt32(IFF_LOOPBACK) != 0 ? "1" : "0"
        }
        return result
    }

    private func recordInterfaceSnapshot(_ rows: [NCMInterfaceBinding.Row], configuration: VPNLoopbackConfiguration, phase: String) {
        interfaceDiagnostic.merge(Self.interfaceSnapshot(rows, configuration: configuration).map { (phase + "." + $0.key, $0.value) }) { _, latest in latest }
    }
    #endif
    /// NEVPNStatus.connected may precede publication of the configured utun.
    /// Wait only for read-only readiness; never restart a VPN or replay a request.
    static func waitForInterface(
        configuration: VPNLoopbackConfiguration, timeout: TimeInterval = 2,
        inventory: @MainActor () throws -> [NCMInterfaceBinding.Row] = NCMInterfaceBinding.inventory,
        uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }
    ) async throws -> NCMInterfaceBinding.Row {
        let deadline = uptime() + timeout
        while true {
            try Task.checkCancellation()
            do { return try selectInterface(inventory(), configuration: configuration) }
            catch LocalVPNError.inactive {
                guard uptime() < deadline else { throw LocalVPNError.inactive }
            }
            try await pause()
        }
    }
    public func discoverPort(configuration: VPNLoopbackConfiguration = .defaults) async throws -> UInt16 {
        try Task.checkCancellation()
        guard active == nil else { throw NativeBackendError.busy }
        let search = Search()
        active = search
        #if DEBUG
        interfaceDiagnostic.removeAll()
        #endif
        return try await withTaskCancellationHandler {
            do {
                _ = try await Self.waitForInterface(configuration: configuration, inventory: {
                    guard self.active === search else { throw CancellationError() }
                    let rows = try NCMInterfaceBinding.inventory()
                    #if DEBUG
                    self.recordInterfaceSnapshot(rows, configuration: configuration,
                        phase: self.interfaceDiagnostic.isEmpty ? "initial" : "readiness")
                    #endif
                    return rows
                })
                try Task.checkCancellation()
                guard active === search else { throw CancellationError() }
                return try await withCheckedThrowingContinuation { reply in
                    search.pending = reply
                    search.browser.delegate = self
                    search.deadline = Task { @MainActor [weak self, weak search] in
                        do { try await Task.sleep(for: .seconds(4)) } catch { return }
                        guard let self, let search, self.active === search else { return }
                        #if DEBUG
                        if let rows = try? NCMInterfaceBinding.inventory() {
                            self.recordInterfaceSnapshot(rows, configuration: configuration, phase: "discoveryEnd")
                        }
                        #endif
                        self.complete(search, result: Result { try Self.selectPort(Array(search.resolved.values)) })
                    }
                    search.browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
                }
            } catch {
                complete(search, result: .failure(error))
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(search, result: .failure(CancellationError())) }
        }
    }

    public func cancel() {
        guard let search = active else { return }
        complete(search, result: .failure(CancellationError()))
    }
    private func complete(_ search: Search, result: Result<UInt16, Error>) {
        guard active === search else { return }
        active = nil
        let reply = search.pending
        search.pending = nil
        search.stop()
        reply?.resume(with: result)
    }
    private static func key(_ service: NetService) -> String {
        [service.domain, service.type, service.name].joined(separator: "\0")
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard let search = active, search.browser === browser else { return }
        let key = Self.key(service)
        guard search.candidates[key] == nil, search.candidates.count < 64 else { return }
        search.candidates[key] = service
        service.delegate = self
        service.resolve(withTimeout: 3)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard let search = active, search.browser === browser else { return }
        let key = Self.key(service)
        search.resolved[key] = nil
        if let removed = search.candidates.removeValue(forKey: key) { removed.delegate = nil; removed.stop() }
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard let search = active, search.browser === browser else { return }
        complete(search, result: .failure(LocalVPNError.discoveryDenied))
    }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let search = active, search.candidates[Self.key(sender)] === sender,
              let port = UInt16(exactly: sender.port), port != 0 else { return }
        let own = Self.localAddressSet()
        let belongsToPhone = (sender.addresses ?? []).contains { address in
            address.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr>.size else { return false }
                guard let host = Self.numericAddress(base.assumingMemoryBound(to: sockaddr.self), capacity: raw.count) else { return false }
                return own.contains(host)
            }
        }
        if belongsToPhone { search.resolved[Self.key(sender)] = port }
    }
    private static func numericAddress(_ pointer: UnsafePointer<sockaddr>, capacity: Int) -> String? {
        let length = Int(pointer.pointee.sa_len)
        let family = Int32(pointer.pointee.sa_family)
        guard (family == AF_INET || family == AF_INET6), length > 0, length <= capacity else { return nil }
        let required = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
        guard length >= required else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(pointer, socklen_t(length), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        // The service port and the IPv6 interface scope are not host identity.
        return String(cString: host).split(separator: "%", maxSplits: 1).first.map(String.init)
    }
    private static func localAddressSet() -> Set<String> {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return [] }
        defer { freeifaddrs(addresses) }
        var result = Set<String>()
        var cursor = addresses
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let socket = entry.pointee.ifa_addr,
                  let name = numericAddress(UnsafePointer(socket), capacity: Int(socket.pointee.sa_len)) else { continue }
            result.insert(name)
        }
        return result
    }
}
