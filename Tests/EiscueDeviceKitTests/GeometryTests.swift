import Foundation
import Testing
@testable import EiscueDeviceKit
@testable import EiscueDeviceCore
@testable import EiscueDeviceBackend

@Suite struct GeometryTests {
    private let portrait = CGRect(x: 0, y: 8, width: 100, height: 200)
    private let landscape = CGRect(x: 0, y: 8, width: 200, height: 100)

    private func update(_ tracker: inout NCMVideoGeometryTracker, epoch: UInt64 = 1,
                        revision: UInt64 = 1, rect: CGRect? = nil,
                        bufferWidth: Int = 208, bufferHeight: Int = 208) -> NativeVideoGeometry {
        tracker.update(epoch: epoch, revision: revision, bufferWidth: bufferWidth,
                       bufferHeight: bufferHeight, visibleRect: rect ?? portrait)
    }

    @Test func unchangedGeometryRetainsCoordinateSpaceAcrossPictures() {
        var tracker = NCMVideoGeometryTracker()
        let original = update(&tracker)
        #expect(update(&tracker) == original)
        #expect(original.epoch == 1)
        #expect(original.revision == 1)
    }

    @Test func rotationBackToOriginalDimensionsDoesNotRestoreOldCoordinateSpace() throws {
        var tracker = NCMVideoGeometryTracker()
        let original = update(&tracker)
        let rotated = update(&tracker, rect: landscape)
        let returned = update(&tracker)
        #expect(original.id != rotated.id)
        #expect(original.id != returned.id)
        #expect(rotated.id != returned.id)


    }

    @Test func visibleOriginChangesInvalidateEvenWithSamePixelDimensions() {
        var tracker = NCMVideoGeometryTracker()
        let original = update(&tracker)
        let shifted = update(&tracker, rect: CGRect(x: 1, y: 8, width: 100, height: 200))
        #expect(original.id != shifted.id)
    }

    @Test func epochRevisionBufferAndResetEachInvalidateIdentity() {
        var tracker = NCMVideoGeometryTracker()
        let initial = update(&tracker)
        let newEpoch = update(&tracker, epoch: 2)
        #expect(initial.id != newEpoch.id)
        let newRevision = update(&tracker, epoch: 2, revision: 2)
        #expect(newEpoch.id != newRevision.id)
        let newBuffer = update(&tracker, epoch: 2, revision: 2, bufferWidth: 216)
        #expect(newRevision.id != newBuffer.id)
        tracker.reset()
        #expect(tracker.current == nil)
        let restarted = update(&tracker, epoch: 2, revision: 2, bufferWidth: 216)
        #expect(newBuffer.id != restarted.id)
    }

    @Test @MainActor func continuousAnimationDoesNotMoveTheAdmittedDecodeBarrier() async throws {
        var tracker = NCMVideoGeometryTracker()
        let geometry = update(&tracker)
        var serial: UInt64 = 10
        let result = try await NCMVideoGeometryRead.read(cursor: {
            serial += 1
            return .init(epoch: 1, serial: serial)
        }, decoded: { (geometry, 11) }, wait: { throw GeometryReadFixtureError.unexpectedRetry })
        #expect(result == geometry)
        #expect(serial == 12, "A newer same-epoch picture must not require another catch-up cycle.")
    }

    @Test @MainActor func peerGeometryReceiptRequiresOneExactBooleanByte() throws {
        #expect(try NCMVideoGeometryRead.peerConfirmed(Data([1])))
        #expect(try !NCMVideoGeometryRead.peerConfirmed(Data([0])))
        for receipt in [Data(), Data([2]), Data([255]), Data([1, 0])] {
            #expect(throws: NativeBackendError.malformedEvent) { try NCMVideoGeometryRead.peerConfirmed(receipt) }
        }
    }

    @Test @MainActor func queuedPicturesAtAdmissionMustDecodeAndTheirChangedGeometryIsReturned() async throws {
        var tracker = NCMVideoGeometryTracker()
        let original = update(&tracker)
        let shifted = update(&tracker, rect: CGRect(x: 1, y: 8, width: 100, height: 200))
        var cursorReads = 0, decoderReads = 0, waits = 0
        let result = try await NCMVideoGeometryRead.read(cursor: {
            cursorReads += 1
            return .init(epoch: 1, serial: cursorReads == 1 ? 10 : 100)
        }, decoded: {
            decoderReads += 1
            return decoderReads == 1 ? (original, 9) : (shifted, 10)
        }, wait: { waits += 1 })
        #expect(decoderReads == 2)
        #expect(waits == 1, "An old decoded picture cannot skip the initial barrier.")
        #expect(result == shifted)
        #expect(result?.id != original.id, "The caller must see a changed crop identity and reject its old grant.")
    }

    @Test @MainActor func geometryReadRefusesEpochChangesSyncLossAndMissingOrBehindDecoder() async throws {
        var tracker = NCMVideoGeometryTracker()
        let geometry = update(&tracker)
        let otherEpoch = update(&tracker, epoch: 2)
        typealias State = (geometry: NativeVideoGeometry, serial: UInt64)
        let scenarios: [(UInt64, UInt64, UInt64, State?)] = [
            (0, 1, 10, (geometry, 10)),
            (10, 1, 0, (geometry, 10)),
            (10, 2, 10, (otherEpoch, 10)),
            (10, 3, 10, (geometry, 10)),
            (10, 1, 10, nil),
            (10, 1, 10, (otherEpoch, 10)),
            (10, 1, 10, (geometry, 9))
        ]
        for (initialSerial, currentEpoch, currentSerial, decoded) in scenarios {
            var reads = 0
            let result = try await NCMVideoGeometryRead.read(cursor: {
                reads += 1
                return .init(epoch: reads == 1 ? 1 : currentEpoch, serial: reads == 1 ? initialSerial : currentSerial)
            }, decoded: { decoded }, timeout: .zero, wait: {})
            #expect(result == nil)
        }
    }

}

private enum GeometryReadFixtureError: Error { case unexpectedRetry }
