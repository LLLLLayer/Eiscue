import EiscueDeviceCore
import Darwin
import Foundation
import dnssd
@preconcurrency import EiscueDeviceBackend

/// Publishes the local VPN peer as a separate Bonjour host. Settings discovery
/// through this alias still needs real-device verification.
final class LoopbackPairingPublisher: Sendable {
    enum Event: Sendable {
        case published
        case failed(DeviceControlError)
    }

    // The native service name is reused; order old teardown before a new start.
    private static let queue = DispatchQueue(label: "org.eiscue.device.loopback-pairing")
    private let registration: Registration

    init(advertisement: PairingAdvertisement, configuration: VPNLoopbackConfiguration,
         update: @escaping @Sendable (Event) -> Void) throws {
        let endpoint = try Self.publicationEndpoint(configuration: configuration)
        let txt = NetService.data(fromTXTRecord: advertisement.txt.mapValues { Data($0.utf8) })
        guard endpoint.address.count == 4, advertisement.port != 0,
              (1...63).contains(advertisement.identifier.utf8.count),
              !advertisement.identifier.utf8.contains(0), txt.count <= Int(UInt16.max) else {
            throw Self.failure(DNSServiceErrorType(kDNSServiceErr_BadParam))
        }
        registration = Registration(queue: Self.queue, identifier: advertisement.identifier, port: advertisement.port,
                                    txt: txt, endpoint: endpoint, update: update)
        let registration = registration
        Self.queue.async { registration.start() }
    }

    deinit {
        let registration = registration
        Self.queue.async { registration.stop() }
    }

    func stop() {
        let registration = registration
        Self.queue.async { registration.stop() }
    }

    private struct PublicationEndpoint: Sendable {
        let interfaceIndex: UInt32
        let address: Data
    }

    private static func publicationEndpoint(configuration: VPNLoopbackConfiguration) throws -> PublicationEndpoint {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--pairing-local-interface") {
            var head: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&head) == 0, let head else { throw failure(DNSServiceErrorType(kDNSServiceErr_BadParam)) }
            defer { freeifaddrs(head) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = head
            var candidate: PublicationEndpoint?
            while let current = cursor {
                let row = current.pointee
                cursor = row.ifa_next
                guard let name = row.ifa_name, String(cString: name) == "en0",
                      row.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                      let address = row.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
                let index = if_nametoindex(name)
                let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                guard index != 0, ipv4.s_addr != 0, candidate == nil else { throw failure(DNSServiceErrorType(kDNSServiceErr_BadParam)) }
                // sin_addr already holds network-order bytes; do not swap them.
                candidate = PublicationEndpoint(interfaceIndex: index, address: withUnsafeBytes(of: ipv4) { Data($0) })
            }
            guard let candidate else { throw failure(DNSServiceErrorType(kDNSServiceErr_BadParam)) }
            return candidate
        }
        #endif
        let address = configuration.peerAddress.split(separator: ".").compactMap { UInt8($0) }
        return PublicationEndpoint(interfaceIndex: UInt32(kDNSServiceInterfaceIndexAny), address: Data(address))
    }

    private static func failure(_ code: DNSServiceErrorType) -> DeviceControlError {
        if code == kDNSServiceErr_PolicyDenied || code == kDNSServiceErr_NotPermitted {
            return .connection(String(localized: "device.pairing.network-denied", defaultValue: "Could not make pairing available. Allow Local Network access for Eiscue.", bundle: EiscueDeviceResources.bundle))
        }
        return .connection(String(localized: "device.pairing.publish-failed", defaultValue: "Could not make system pairing available.", bundle: EiscueDeviceResources.bundle))
    }

    // DNS-SD calls, callbacks, references and their contexts live exclusively on
    // this serial queue, including deallocation required by SetDispatchQueue.
    private final class Registration: @unchecked Sendable {
        private let queue: DispatchQueue
        private let identifier: String
        private let port: UInt16
        private let txt: Data
        private let endpoint: PublicationEndpoint
        private let hostname = "eiscue-pairing-\(UUID().uuidString.lowercased()).local."
        private let update: @Sendable (Event) -> Void
        private var token: UUID? = UUID()
        private var addressService: DNSServiceRef?
        private var service: DNSServiceRef?
        private var addressRecord: DNSRecordRef?
        private var addressContext: CallbackContext?
        private var serviceContext: CallbackContext?
        private var addressPublished = false
        private var servicePublished = false
        private var notified = false

        init(queue: DispatchQueue, identifier: String, port: UInt16, txt: Data, endpoint: PublicationEndpoint,
             update: @escaping @Sendable (Event) -> Void) {
            self.queue = queue; self.identifier = identifier; self.port = port
            self.txt = txt; self.endpoint = endpoint; self.update = update
        }

        func start() {
            dispatchPrecondition(condition: .onQueue(queue))
            guard let token else { return }
            let addressContext = CallbackContext(registration: self, token: token)
            let serviceContext = CallbackContext(registration: self, token: token)
            self.addressContext = addressContext; self.serviceContext = serviceContext

            var code = DNSServiceCreateConnection(&addressService)
            guard code == kDNSServiceErr_NoError, let addressService else { fail(code); return }
            code = endpoint.address.withUnsafeBytes { bytes in
                DNSServiceRegisterRecord(addressService, &addressRecord, DNSServiceFlags(kDNSServiceFlagsUnique),
                    endpoint.interfaceIndex, hostname, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                    UInt16(bytes.count), bytes.baseAddress, 0, { reference, record, _, code, context in
                        guard let context else { return }
                        let value = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
                        value.registration?.addressReply(reference: reference, record: record, code: code, token: value.token)
                    }, Unmanaged.passUnretained(addressContext).toOpaque())
            }
            guard code == kDNSServiceErr_NoError, addressRecord != nil else { fail(code); return }
            code = DNSServiceSetDispatchQueue(addressService, queue)
            guard code == kDNSServiceErr_NoError else { fail(code); return }

            code = txt.withUnsafeBytes { bytes in
                DNSServiceRegister(&service, DNSServiceFlags(kDNSServiceFlagsNoAutoRename),
                    endpoint.interfaceIndex, identifier, "_remotepairing-pairable-host._tcp.", "local.",
                    hostname, port.bigEndian, UInt16(bytes.count), bytes.baseAddress, { reference, flags, code, _, _, _, context in
                        guard let context else { return }
                        let value = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
                        value.registration?.serviceReply(reference: reference, flags: flags, code: code, token: value.token)
                    }, Unmanaged.passUnretained(serviceContext).toOpaque())
            }
            guard code == kDNSServiceErr_NoError, let service else { fail(code); return }
            code = DNSServiceSetDispatchQueue(service, queue)
            guard code == kDNSServiceErr_NoError else { fail(code); return }
        }

        func stop() {
            dispatchPrecondition(condition: .onQueue(queue))
            token = nil
            if let service { DNSServiceRefDeallocate(service) }
            if let addressService { DNSServiceRefDeallocate(addressService) }
            service = nil; addressService = nil; addressRecord = nil
            serviceContext = nil; addressContext = nil
        }

        private func addressReply(reference: DNSServiceRef?, record: DNSRecordRef?, code: DNSServiceErrorType, token: UUID) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard self.token == token, reference == addressService else { return }
            guard code == kDNSServiceErr_NoError else { fail(code); return }
            guard record == addressRecord else { fail(DNSServiceErrorType(kDNSServiceErr_Unknown)); return }
            addressPublished = true; notifyIfPublished()
        }

        private func serviceReply(reference: DNSServiceRef?, flags: DNSServiceFlags, code: DNSServiceErrorType, token: UUID) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard self.token == token, reference == service else { return }
            guard code == kDNSServiceErr_NoError else { fail(code); return }
            guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 else { fail(DNSServiceErrorType(kDNSServiceErr_Unknown)); return }
            servicePublished = true; notifyIfPublished()
        }

        private func notifyIfPublished() {
            guard addressPublished, servicePublished, !notified else { return }
            notified = true; update(.published)
        }

        private func fail(_ code: DNSServiceErrorType) {
            guard token != nil else { return }
            stop(); update(.failed(LoopbackPairingPublisher.failure(code)))
        }
    }

    private final class CallbackContext {
        weak var registration: Registration?
        let token: UUID
        init(registration: Registration, token: UUID) { self.registration = registration; self.token = token }
    }
}
