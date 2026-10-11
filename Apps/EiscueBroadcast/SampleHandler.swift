import CoreImage
import ImageIO
import ReplayKit

/// ReplayKit invokes its callbacks serially. The dedicated queue also serializes
/// the stop timer with those callbacks, including while the broadcast is paused.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "org.eiscue.app.broadcast.frames")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var store: ScreenBroadcastStore?
    private var sessionID: UUID?
    private var stopTimer: DispatchSourceTimer?
    private var lastFrameUptime: TimeInterval = 0
    private var paused = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        workQueue.sync {
            do {
                let store = try ScreenBroadcastStore()
                self.store = store
                sessionID = try store.beginSession()
                paused = false
                lastFrameUptime = 0
                let timer = DispatchSource.makeTimerSource(queue: workQueue)
                timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
                timer.setEventHandler { [weak self] in self?.checkStop() }
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
                lastFrameUptime = 0
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
            guard !paused, let store, let sessionID else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            guard uptime - lastFrameUptime >= 0.5 else { return }
            lastFrameUptime = uptime
            autoreleasepool {
                do {
                    guard !(try store.stopRequested(sessionID: sessionID)) else {
                        endWithError(key: "broadcast.ended")
                        return
                    }
                    guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
                          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                    let attachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                        attachmentModeOut: nil) as? NSNumber
                    let orientation = CGImagePropertyOrientation(rawValue: attachment?.uint32Value ?? 1) ?? .up
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
                    try store.publish(jpegData: jpeg, width: width, height: height,
                        orientation: ScreenBroadcastOrientation(rawValue: orientation.rawValue) ?? .up,
                        sessionID: sessionID)
                } catch {
                    // A locked shared container, invalid frame or changed session
                    // ends sharing; a previously valid frame is never reused.
                    endWithError(key: "broadcast.unavailable")
                }
            }
        }
    }

    private func checkStop() {
        guard let store, let sessionID else { return }
        // Opening the protected latest record fails on device lock, even when
        // ReplayKit has stopped delivering buffers without a pause callback.
        let state = store.state()
        guard state.phase != .unavailable, state.sessionID == sessionID else {
            endWithError(key: "broadcast.unavailable")
            return
        }
        do {
            if try store.stopRequested(sessionID: sessionID) { endWithError(key: "broadcast.ended") }
        } catch { endWithError(key: "broadcast.unavailable") }
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
        paused = true
        context.clearCaches()
    }
}
