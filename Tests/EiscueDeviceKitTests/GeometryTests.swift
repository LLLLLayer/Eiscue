import Foundation
import Testing
@testable import EiscueDeviceKit
@testable import EiscueDeviceCore
@testable import PhoneAgentNCM

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

}
