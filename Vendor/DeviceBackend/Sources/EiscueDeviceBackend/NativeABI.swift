// SPDX-License-Identifier: GPL-3.0-only
// Eiscue's bounded ownership adapter for the versioned C ABI.
import Foundation
import CEiscueDeviceBackend

enum NativeEventReader {
    struct Message {
        let header: ncm_event
        var payload: Data

        func validate(request: UInt64) throws {
            guard header.request_id == request, header.reserved == 0,
                  header.size == payload.count else { throw NativeBackendError.malformedEvent }
        }
        func checkFailure() throws {
            switch header.kind {
            case 3: throw NativeBackendError.protocolFailure(stage: header.stage, cause: header.cause)
            case 10: throw NativeBackendError.touchPreparationFailure(stage: header.stage, cause: header.cause)
            case 12: throw NativeBackendError.applicationQueryFailure(stage: header.stage, cause: header.cause)
            default: return
            }
        }
    }

    // The probe does not consume a payload event. The second call must return
    // the same envelope; accepting a changed envelope could settle another RPC.
    static func poll(limit: Int, read: (UnsafeMutablePointer<ncm_event>, UnsafeMutablePointer<UInt8>?, Int) -> Int32) throws -> Message? {
        var header = ncm_event()
        switch read(&header, nil, 0) {
        case 4: return nil
        case 3: throw NativeBackendError.closed
        case 0:
            guard header.size == 0 else { throw NativeBackendError.malformedEvent }
            return Message(header: header, payload: Data())
        case 5: break
        case let code: throw NativeBackendError.transport(code: code)
        }
        guard (1...limit).contains(header.size) else { throw NativeBackendError.malformedEvent }
        let expected = header
        var payload = Data(count: expected.size)
        let status = payload.withUnsafeMutableBytes { storage in
            read(&header, storage.bindMemory(to: UInt8.self).baseAddress, storage.count)
        }
        guard status == 0 else {
            payload.resetBytes(in: 0..<payload.count)
            throw status == 3 ? NativeBackendError.closed : .transport(code: status)
        }
        guard header.kind == expected.kind, header.request_id == expected.request_id,
              header.stage == expected.stage, header.cause == expected.cause,
              header.reserved == expected.reserved, header.size == expected.size else {
            payload.resetBytes(in: 0..<payload.count)
            throw NativeBackendError.malformedEvent
        }
        return Message(header: header, payload: payload)
    }
}

enum NativeVideoMailbox {
    case idle, reset, picture(Data)

    static func poll(read: (UnsafeMutablePointer<ncm_event>, UnsafeMutablePointer<UInt8>?, Int) -> Int32) throws -> Self {
        var envelope = ncm_event()
        let probe = read(&envelope, nil, 0)
        if probe == 4 { return .idle }
        if probe == 3 { throw NativeBackendError.closed }
        if probe == 0 && envelope.kind == 14 { return .reset }
        guard probe == 5, envelope.kind == 13, (64...8 * 1024 * 1024).contains(envelope.size) else {
            throw NativeBackendError.screenshotFailure(stage: 20, cause: 1)
        }
        var allocation = Data(count: envelope.size)
        let status = allocation.withUnsafeMutableBytes { read(&envelope, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        // Video is a latest-picture mailbox, unlike the ordered RPC queue. A
        // reset or a larger replacement can legitimately win the probe/copy race.
        switch status {
        case 4, 5: return .idle
        case 3: throw NativeBackendError.closed
        case 0 where envelope.kind == 14: return .reset
        case 0 where envelope.kind == 13 && (64...allocation.count).contains(envelope.size):
            return .picture(Data(allocation.prefix(envelope.size)))
        default: throw NativeBackendError.screenshotFailure(stage: 20, cause: 1)
        }
    }
}

// One temporary allocation owns every borrowed slice. Its lifetime cannot escape
// the synchronous ABI call; wipe it before freeing, including on thrown errors.
func withSlices<R>(_ values: [Data], _ body: ([ncm_bytes]) throws -> R) rethrows -> R {
    let size = values.reduce(0) { $0 + $1.count }
    let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, size))
    defer { storage.update(repeating: 0, count: size); storage.deallocate() }
    var offset = 0
    let slices = values.map { value -> ncm_bytes in
        let address = storage.advanced(by: offset)
        value.copyBytes(to: address, count: value.count)
        offset += value.count
        return ncm_bytes(data: UnsafePointer(address), size: value.count)
    }
    return try body(slices)
}

func withNativeIdentity<R>(_ identity: AuthorizedRemoteIdentity, _ body: (inout ncm_identity) throws -> R) rethrows -> R {
    try withSlices([identity.signingSeed, Data(identity.controllerID.utf8), Data(identity.peerID.utf8),
                    identity.peerPublicKey, identity.alternateIRK, Data(identity.peerUDID.utf8), Data(identity.peerModel.utf8)]) { fields in
        var borrowed = ncm_identity(seed: fields[0], controller_id: fields[1], peer_id: fields[2],
                                   peer_public_key: fields[3], alt_irk: fields[4], peer_udid: fields[5], peer_model: fields[6])
        return try body(&borrowed)
    }
}
