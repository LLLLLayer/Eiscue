import AVFAudio
import Speech
import XCTest
@testable import Eiscue

final class SpeechInputCallbackTests: XCTestCase {
    /// Create the production callback from MainActor, just like authorize(),
    /// then invoke it on the background queue used by the real permission API.
    @MainActor func testAuthorizationCallbackCanResumeFromBackgroundQueue() async {
        let status = await withCheckedContinuation { continuation in
            let callback = SpeechInputCallbacks.authorization(continuation)
            DispatchQueue.global(qos: .default).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                callback(.authorized)
            }
        }
        XCTAssertEqual(status, .authorized)
    }

    /// This sends a synthetic PCM buffer through the real tap and request,
    /// without opening a microphone or starting a speech-recognition session.
    @MainActor func testAudioTapAcceptsBackgroundBuffersAndIgnoresBuffersAfterEnd() async {
        let pipe = SpeechAudioPipe(request: SFSpeechAudioBufferRecognitionRequest())
        let callback = SpeechInputCallbacks.audioTap(pipe: pipe)
        let delivered = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32) else {
                    continuation.resume(returning: false)
                    return
                }
                buffer.frameLength = 32
                buffer.floatChannelData?[0].initialize(repeating: 0, count: 32)
                let time = AVAudioTime(sampleTime: 0, atRate: 16_000)
                callback(buffer, time)
                pipe.endAudio()
                callback(buffer, time)
                pipe.endAudio()
                continuation.resume(returning: true)
            }
        }
        XCTAssertTrue(delivered)
    }

    @MainActor func testRecognitionCallbackSnapshotsErrorThenDeliversOnMainActor() async {
        let update = await withCheckedContinuation { continuation in
            let callback = SpeechInputCallbacks.recognition { update in
                MainActor.assertIsolated()
                continuation.resume(returning: update)
            }
            DispatchQueue.global(qos: .default).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                callback(nil, NSError(domain: "SpeechInputCallbackTests", code: 1))
            }
        }
        XCTAssertEqual(update, .init(text: nil, isFinal: false, hasError: true))
    }

    @MainActor func testRecognitionCallbackWithoutResultCanArriveOnBackgroundQueue() async {
        let update = await withCheckedContinuation { continuation in
            let callback = SpeechInputCallbacks.recognition { update in
                MainActor.assertIsolated()
                continuation.resume(returning: update)
            }
            DispatchQueue.global(qos: .default).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                callback(nil, nil)
            }
        }
        XCTAssertEqual(update, .init(text: nil, isFinal: false, hasError: false))
    }
}

