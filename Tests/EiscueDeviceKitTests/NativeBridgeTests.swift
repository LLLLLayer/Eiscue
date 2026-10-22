import Foundation
import Testing
import ImageIO
import CoreVideo
import CEiscueDeviceBackend
@testable import EiscueDeviceBackend

@Suite struct NativeBridgeTests {
    @Test func rpcPayloadCopyMustMatchItsProbedEnvelope() throws {
        var calls = 0
        let message = try #require(NativeEventReader.poll(limit: 8) { header, buffer, capacity in
            calls += 1
            header.pointee = ncm_event(request_id: 7, kind: 2, stage: 0, cause: 0, reserved: 0, size: 3)
            guard let buffer else { return 5 }
            #expect(capacity == 3)
            buffer.update(from: [1, 2, 3], count: 3)
            return 0
        })
        try message.validate(request: 7)
        #expect(message.payload == Data([1, 2, 3]) && calls == 2)
        #expect(throws: NativeBackendError.malformedEvent) { try message.validate(request: 8) }
        calls = 0
        #expect(throws: NativeBackendError.malformedEvent) {
            _ = try NativeEventReader.poll(limit: 8) { header, buffer, _ in
                calls += 1
                header.pointee = ncm_event(request_id: buffer == nil ? 7 : 8, kind: 2, stage: 0, cause: 0, reserved: 0, size: 1)
                buffer?.pointee = 1
                return buffer == nil ? 5 : 0
            }
        }
        #expect(calls == 2)
    }

    @Test func rpcReaderRejectsUnboundedPayloadBeforeAllocation() throws {
        var copies = 0
        #expect(throws: NativeBackendError.malformedEvent) {
            _ = try NativeEventReader.poll(limit: 8) { header, buffer, _ in
                if buffer != nil { copies += 1 }
                header.pointee.size = 9
                return 5
            }
        }
        #expect(copies == 0)
        #expect(throws: NativeBackendError.closed) { _ = try NativeEventReader.poll(limit: 8) { _, _, _ in 3 } }
        #expect(try NativeEventReader.poll(limit: 8) { _, _, _ in 4 } == nil)
    }

    @Test(arguments: [Int32(4), 5, 0])
    func videoMailboxAcceptsReplacementWithoutMisreadingBytes(status: Int32) throws {
        var calls = 0
        let value = try NativeVideoMailbox.poll { header, buffer, _ in
            calls += 1
            header.pointee.kind = buffer == nil ? 13 : 14
            header.pointee.size = buffer == nil ? 64 : 0
            return buffer == nil ? 5 : status
        }
        #expect(calls == 2)
        switch value {
        case .idle: #expect(status == 4 || status == 5)
        case .reset: #expect(status == 0)
        case .picture: Issue.record("A raced mailbox must not expose its allocation as a picture")
        }
    }

    @Test func identityArenaKeepsEverySliceDistinctForTheSynchronousCall() throws {
        let identity = try AuthorizedRemoteIdentity(signingSeed: Data(repeating: 1, count: 32), controllerID: "controller",
            peerID: "peer", peerPublicKey: Data(repeating: 2, count: 32), alternateIRK: Data(repeating: 3, count: 16),
            peerUDID: "udid", peerModel: "model")
        withNativeIdentity(identity) { raw in
            #expect(Data(bytes: raw.seed.data!, count: raw.seed.size) == Data(repeating: 1, count: 32))
            #expect(Data(bytes: raw.peer_public_key.data!, count: raw.peer_public_key.size) == Data(repeating: 2, count: 32))
            #expect(Data(bytes: raw.alt_irk.data!, count: raw.alt_irk.size) == Data(repeating: 3, count: 16))
            #expect(String(decoding: UnsafeBufferPointer(start: raw.controller_id.data, count: raw.controller_id.size), as: UTF8.self) == "controller")
            #expect(raw.seed.data != raw.peer_public_key.data && raw.peer_id.data != raw.controller_id.data)
        }
    }

    @Test func videoWireParserValidatesExactLengthsAndNALBoundaries() throws {
        let fixture = sample(serial: 1)
        let decoded = try NCMVideoSample(fixture)
        #expect(decoded.width == 64 && decoded.height == 64 && decoded.sync && decoded.serial == 1)
        #expect(decoded.parameters.count == 3 && decoded.visibleSize == nil)
        for bad in [Data(fixture.dropLast()), fixture + Data([0]), Data(fixture.prefix(63))] {
            #expect(throws: NativeBackendError.malformedEvent) { _ = try NCMVideoSample(bad) }
        }
        var badFlags = fixture
        badFlags[36] = 4
        #expect(throws: NativeBackendError.malformedEvent) { _ = try NCMVideoSample(badFlags) }
        #expect(throws: NativeBackendError.malformedEvent) { _ = try NCMVideoSample(sample(serial: 0)) }
        #expect(throws: NativeBackendError.malformedEvent) { _ = try NCMVideoSample(sample(serial: 1, nal: Data([0, 0, 0, 9, 0x26, 1]))) }
    }

    @Test func displayFooterStripsOnlyValidMatchingGeometry() throws {
        let slice = Data([0x26, 1, 0x80, 0x55])
        // The zero runs cross the slice/footer boundary after EBSP escaping.
        let footer: [UInt8] = [0, 0, 0, 0, 0, 60, 0, 61, 2]
        let encoded = framed(Data(slice.prefix(2)) + escape(Data(slice.dropFirst(2)) + Data(footer)))
        let picture = try NCMDisplayPicture(encoded, codedWidth: 64, codedHeight: 64)
        #expect(picture.bytes == framed(slice))
        #expect(picture.visibleWidth == 60 && picture.visibleHeight == 61)
        let rejected = try NCMDisplayPicture(encoded, codedWidth: 32, codedHeight: 32)
        #expect(rejected.bytes == encoded && rejected.visibleWidth == nil)
        let conflicting = framed(Data(slice.prefix(2)) + escape(Data(slice.dropFirst(2)) + Data([0, 0, 0, 0, 0, 59, 0, 61, 2])))
        #expect(throws: NativeBackendError.malformedEvent) { _ = try NCMDisplayPicture(encoded + conflicting, codedWidth: 64, codedHeight: 64) }
    }

    @Test func syntheticHEVCDecodeKeepsFreshnessAndGeometryAuthority() async throws {
        let decoder = NCMVideoDecoder()
        let began = ContinuousClock.now
        #expect(try await decoder.consume(sample(serial: 1)))
        let first = try #require(try await decoder.jpegWithGeometry(notBefore: began))
        let source = try #require(CGImageSourceCreateWithData(first.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 64)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 64)
        let later = ContinuousClock.now
        #expect(try await decoder.jpegWithGeometry(notBefore: later) == nil)
        #expect(try await decoder.jpegWithGeometry(notBefore: later, confirmedEpoch: 99, confirmedSerial: 1) == nil)
        #expect(try await decoder.jpegWithGeometry(notBefore: later, confirmedEpoch: 1, confirmedSerial: 1)?.geometry == first.geometry)
        #expect(try await decoder.consume(sample(serial: 3)))
        let afterGap = try #require(await decoder.currentGeometry())
        #expect(afterGap.geometry.id != first.geometry.id)
        await decoder.reset()
        #expect(await decoder.currentGeometry() == nil)
        #expect(try await decoder.jpegWithGeometry(notBefore: began, confirmedEpoch: 1, confirmedSerial: 3) == nil)
    }

    @Test func decodeFailureRevokesPixelsAndWaitsForAnotherKeyframe() async throws {
        let decoder = NCMVideoDecoder()
        #expect(try await decoder.consume(sample(serial: 1)))
        await #expect(throws: NativeBackendError.malformedEvent) { _ = try await decoder.consume(sample(serial: 1)) }
        #expect(await decoder.currentGeometry() == nil)
        var predicted = sample(serial: 2)
        predicted[36] = 0
        #expect(try await decoder.consume(predicted) == false)
        #expect(await decoder.currentGeometry() == nil)
        #expect(try await decoder.consume(sample(serial: 3)))
        #expect(await decoder.currentGeometry() != nil)
    }

    @Test func vpnConfigurationRejectsNoncanonicalAndNonUnicastAddresses() throws {
        for address in ["010.7.1.1", "127.0.0.1", "224.0.0.1", "0.1.1.1", "10.7.1", "10.7.1.256", "10.7.1.1\0ignored"] {
            #expect(throws: LocalVPNError.invalidConfiguration) { _ = try VPNLoopbackConfiguration(localAddress: address, peerAddress: "10.7.0.1") }
        }
        #expect(try VPNLoopbackConfiguration(localAddress: " 10.7.1.1\n", peerAddress: "10.7.0.1") == .defaults)
    }

    private func framed(_ nal: Data) -> Data {
        var length = UInt32(nal.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + nal
    }
    private func escape(_ rbsp: Data) -> Data {
        var result = Data(), zeroCount = 0
        for byte in rbsp {
            if zeroCount == 2 && byte <= 3 { result.append(3); zeroCount = 0 }
            result.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return result
    }
    private func sample(serial: UInt64, nal: Data? = nil) -> Data {
        // Generated locally from a solid blue 64×64 lavfi frame with libx265;
        // no captured device pixels or external assets are included.
        let parameters = ["QAEMAf//AWAAAAMAkAAAAwAAAwAelZgJ", "QgEBAWAAAAMAkAAAAwAAAwAeoCCBBZZWaSTK8BaAgAAAAwCAAAADAIQ=", "RAHBcrQiQA=="].map { Data(base64Encoded: $0)! }
        let picture = nal ?? framed(Data(base64Encoded: "KAGvE4DlMlH/+Myiv+K7V/BR0AIX4A==")!)
        var result = Data()
        func number(_ value: UInt64, _ width: Int) {
            for byte in 0..<width { result.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        for value in [serial, 1, 0, 1] { number(value, 8) }
        for value in [UInt64(0), 1, 64, 64] { number(value, 4) }
        for value in parameters + [picture] { number(UInt64(value.count), 4) }
        for value in parameters + [picture] { result.append(value) }
        return result
    }
}

import Network

@Suite @MainActor struct NativeProbeExchangeTests {
    @Test func cancelledExchangeReleasesGateAndCannotCompleteItsReplacement() async throws {
        let server = try ProbeServer()
        let port = try await server.start()
        defer { server.stop() }
        let client = NCMProbeClient()
        let pending = Task { try await client.exchange(.status, connection: server.connection(port), timeout: .seconds(2)) }
        try await waitUntil { server.requests == 1 }
        await #expect(throws: NCMError.busy) {
            _ = try await client.exchange(.status, connection: server.connection(port))
        }
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        server.respond = true
        let reply = try await client.exchange(.status, connection: server.connection(port), timeout: .seconds(2))
        #expect(reply.result == "diagnostic-only" && server.requests == 2)
    }

    @Test func timedOutExchangeClosesAndAllowsTheNextRequest() async throws {
        let server = try ProbeServer()
        let port = try await server.start()
        defer { server.stop() }
        let client = NCMProbeClient()
        await #expect(throws: NCMError.timeout) {
            _ = try await client.exchange(.status, connection: server.connection(port), timeout: .milliseconds(100))
        }
        server.respond = true
        let reply = try await client.exchange(.status, connection: server.connection(port), timeout: .seconds(2))
        #expect(!reply.authenticated && reply.layer == "ncm")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NCMError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor private final class ProbeServer {
    private let listener: NWListener
    private var ready: CheckedContinuation<NWEndpoint.Port, Error>?
    private var sockets: [NWConnection] = []
    var requests = 0
    var respond = false
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { ready = $0
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener.port { self.ready?.resume(returning: port); self.ready = nil }
                    case .failed(let error): self.ready?.resume(throwing: error); self.ready = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
    }
    func connection(_ port: NWEndpoint.Port) -> NWConnection { NWConnection(host: "127.0.0.1", port: port, using: .tcp) }
    private func accept(_ socket: NWConnection) {
        sockets.append(socket)
        socket.start(queue: .main)
        socket.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] bytes, _, _, _ in
            Task { @MainActor in
                guard let self, bytes != nil else { return }
                self.requests += 1
                guard self.respond else { return }
                let reply = Data("{\"protocol\":\"ND1\",\"layer\":\"ncm\",\"result\":\"diagnostic-only\",\"authenticated\":false}\n".utf8)
                socket.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
    }
    func stop() {
        listener.cancel()
        sockets.forEach { $0.cancel() }
        ready?.resume(throwing: CancellationError()); ready = nil
    }
}
