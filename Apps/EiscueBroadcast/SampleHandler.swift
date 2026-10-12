import CoreImage
import ImageIO
import ReplayKit

/// ReplayKit invokes its callbacks serially. The dedicated queue also serializes
/// the stop timer with those callbacks, including while the broadcast is paused.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "org.eiscue.app.broadcast.frames")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let publishInterval: TimeInterval = 0.5
    private var store: ScreenBroadcastStore?
    private var sessionID: UUID?
    private var stopTimer: DispatchSourceTimer?
    private var lastFrameUptime: TimeInterval = 0
    private var publishedFrameID: UUID?
    // Any delivered buffer means the stored frame may no longer be the newest
    // screen; the heartbeat must not confirm it until a later publish succeeds.
    private var newerFramePending = false
    // ReplayKit may send nothing more once the screen settles, so the newest
    // throttled buffer is copied (buffers are valid only during the callback)
    // and published when the interval allows. One owned buffer is reused.
    private var ownedBuffer: CVPixelBuffer?
    private var pendingOrientation: CGImagePropertyOrientation?
    private var paused = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        workQueue.sync {
            do {
                let store = try ScreenBroadcastStore()
                self.store = store
                sessionID = try store.beginSession()
                paused = false
                resetFrames()
                let timer = DispatchSource.makeTimerSource(queue: workQueue)
                timer.schedule(deadline: .now() + Self.publishInterval, repeating: Self.publishInterval)
                timer.setEventHandler { [weak self] in self?.tick() }
                stopTimer = timer
                timer.resume()
            } catch {
                endWithError(key: "broadcast.unavailable")
            }
        }
    }

    override func broadcastPaused() {
        workQueue.sync {
            paused = true
            resetFrames(releasingBuffer: true)
            if let store, let sessionID {
                do { try store.setPaused(true, sessionID: sessionID) }
                catch { endWithError(key: "broadcast.unavailable") }
            }
            context.clearCaches()
        }
    }

    override func broadcastResumed() {
        workQueue.sync {
            guard let store, let sessionID else { return }
            do {
                try store.setPaused(false, sessionID: sessionID)
                paused = false
                resetFrames()
            } catch { endWithError(key: "broadcast.unavailable") }
        }
    }

    override func broadcastFinished() {
        workQueue.sync { cleanUp() }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // App and microphone audio are never recorded, retained or transmitted.
        guard sampleBufferType == .video else { return }
        workQueue.sync {
            guard !paused, store != nil, sessionID != nil else { return }
            newerFramePending = true
            pendingOrientation = nil
            guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let attachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                attachmentModeOut: nil) as? NSNumber
            let orientation = CGImagePropertyOrientation(rawValue: attachment?.uint32Value ?? 1) ?? .up
            if ProcessInfo.processInfo.systemUptime - lastFrameUptime >= Self.publishInterval {
                publish(pixelBuffer, orientation: orientation)
            } else if let copy = copyIntoOwnedBuffer(pixelBuffer) {
                ownedBuffer = copy; pendingOrientation = orientation
            }
        }
    }

    private func tick() {
        guard let store, let sessionID else { return }
        // Opening the protected latest record fails on device lock, even when
        // ReplayKit has stopped delivering buffers without a pause callback.
        let state = store.state()
        guard state.phase != .unavailable, state.sessionID == sessionID else {
            endWithError(key: "broadcast.unavailable")
            return
        }
        do {
            if try store.stopRequested(sessionID: sessionID) { endWithError(key: "broadcast.ended"); return }
            guard !paused else { return }
            if let orientation = pendingOrientation, let buffer = ownedBuffer,
               ProcessInfo.processInfo.systemUptime - lastFrameUptime >= Self.publishInterval {
                publish(buffer, orientation: orientation)
                guard self.sessionID != nil else { return }
            }
            // ReplayKit sends no buffers while the screen is unchanged. Confirm
            // the stored frame only while no newer buffer is waiting to publish.
            try store.heartbeat(sessionID: sessionID, frameID: publishedFrameID, newerFramePending: newerFramePending)
        } catch { endWithError(key: "broadcast.unavailable") }
    }

    /// Encodes the newest delivered screen. Only a successful publish clears
    /// `newerFramePending`; an unusable buffer leaves the old frame unconfirmed.
    private func publish(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard let store, let sessionID else { return }
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        pendingOrientation = nil
        autoreleasepool {
            do {
                guard !(try store.stopRequested(sessionID: sessionID)) else {
                    endWithError(key: "broadcast.ended")
                    return
                }
                var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
                let extent = image.extent
                guard extent.width.isFinite, extent.height.isFinite,
                      extent.width > 1, extent.height > 1 else { return }
                image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                let scale = min(1, Double(ScreenBroadcastStore.maximumPixelDimension) / max(extent.width, extent.height))
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let width = Int(image.extent.width.rounded(.down))
                let height = Int(image.extent.height.rounded(.down))
                image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.65]) else {
                    throw ScreenBroadcastError.invalidFrame
                }
                publishedFrameID = try store.publish(jpegData: jpeg, width: width, height: height,
                    orientation: ScreenBroadcastOrientation(rawValue: orientation.rawValue) ?? .up,
                    sessionID: sessionID)
                newerFramePending = false
            } catch {
                // A locked shared container, invalid frame or changed session
                // ends sharing; a previously valid frame is never reused.
                endWithError(key: "broadcast.unavailable")
            }
        }
    }

    private func copyIntoOwnedBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        var target = ownedBuffer
        if let current = target, CVPixelBufferGetWidth(current) != width || CVPixelBufferGetHeight(current) != height
            || CVPixelBufferGetPixelFormatType(current) != format { target = nil }
        if target == nil {
            ownedBuffer = nil
            var created: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &created) == kCVReturnSuccess else { return nil }
            target = created
        }
        guard let target, CVPixelBufferIsPlanar(source) == CVPixelBufferIsPlanar(target),
              CVPixelBufferGetPlaneCount(source) == CVPixelBufferGetPlaneCount(target),
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        let planes = CVPixelBufferIsPlanar(source) ? CVPixelBufferGetPlaneCount(source) : 1
        for plane in 0..<planes {
            let planar = CVPixelBufferIsPlanar(source)
            let rows = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : height
            let sourceStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let targetStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(target, plane) : CVPixelBufferGetBytesPerRow(target)
            guard let from = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                  let to = planar ? CVPixelBufferGetBaseAddressOfPlane(target, plane) : CVPixelBufferGetBaseAddress(target),
                  rows == (planar ? CVPixelBufferGetHeightOfPlane(target, plane) : CVPixelBufferGetHeight(target)) else { return nil }
            let rowBytes = min(sourceStride, targetStride)
            for row in 0..<rows { memcpy(to + row * targetStride, from + row * sourceStride, rowBytes) }
        }
        return target
    }

    private func resetFrames(releasingBuffer: Bool = false) {
        lastFrameUptime = 0; publishedFrameID = nil; newerFramePending = false; pendingOrientation = nil
        if releasingBuffer { ownedBuffer = nil }
    }

    private func endWithError(key: String) {
        cleanUp()
        finishBroadcastWithError(NSError(domain: "org.eiscue.app.broadcast", code: 1,
            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(key, comment: "Screen sharing status")]))
    }

    private func cleanUp() {
        stopTimer?.cancel()
        stopTimer = nil
        if let store, let sessionID { try? store.finishSession(sessionID: sessionID) }
        sessionID = nil
        store = nil
        resetFrames(releasingBuffer: true)
        paused = true
        context.clearCaches()
    }
}
