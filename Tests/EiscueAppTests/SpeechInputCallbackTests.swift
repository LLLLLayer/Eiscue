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
                buffer.floatChannelData?[0].initialize(repeating: 0.25, count: 32)
                let time = AVAudioTime(sampleTime: 0, atRate: 16_000)
                callback(buffer, time)
                pipe.endAudio()
                callback(buffer, time)
                pipe.endAudio()
                continuation.resume(returning: true)
            }
        }
        XCTAssertTrue(delivered)
        XCTAssertEqual(pipe.snapshot.buffers, 1)
        XCTAssertEqual(pipe.snapshot.frames, 32)
        XCTAssertEqual(pipe.snapshot.peak, 0.25, accuracy: 0.001)
        XCTAssertTrue(pipe.snapshot.hasInput)
    }

    @MainActor func testZeroBuffersAreNotEvidenceThatTheMicrophoneIsRecording() throws {
        let pipe = SpeechAudioPipe(request: SFSpeechAudioBufferRecognitionRequest())
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 480)
        pipe.append(buffer)
        XCTAssertEqual(pipe.snapshot.frames, 480)
        XCTAssertTrue(pipe.snapshot.readableSamples)
        XCTAssertFalse(pipe.snapshot.hasInput)
        let quietBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        quietBuffer.frameLength = 480
        quietBuffer.floatChannelData?[0].initialize(repeating: 0.000001, count: 480)
        pipe.append(quietBuffer)
        XCTAssertTrue(pipe.snapshot.hasInput, "Very quiet input is different from digitally muted, all-zero buffers.")
        pipe.endAudio()
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
        XCTAssertEqual(update, .init(text: nil, isFinal: false, hasError: true,
                                    errorDomain: "SpeechInputCallbackTests", errorCode: 1))
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

final class SpeechTranscriptBufferTests: XCTestCase {
    func testPauseKeepsEarlierUtteranceWhileOnlyCurrentPartialIsRevised() {
        var buffer = SpeechTranscriptBuffer()
        buffer.receive(update("先打开设置"))
        buffer.receive(update("先打开设置。", start: 0.4, duration: 1.8))
        buffer.receive(update("然后把屏幕调成"))
        XCTAssertEqual(buffer.text, "先打开设置。 然后把屏幕调成")
        buffer.receive(update("然后切换深色模式"))
        XCTAssertEqual(buffer.text, "先打开设置。 然后切换深色模式")
        buffer.receive(update("然后切换深色模式。", start: 7.1, duration: 2.5))
        XCTAssertEqual(buffer.text, "先打开设置。 然后切换深色模式。")
    }

    func testEmptyFinalAfterPauseDoesNotEraseRecognizedSpeech() {
        var buffer = SpeechTranscriptBuffer()
        buffer.receive(update("Keep this sentence.", start: 0.2, duration: 2))
        buffer.receive(update("And this partial"))
        buffer.receive(update("", isFinal: true))
        XCTAssertEqual(buffer.text, "Keep this sentence. And this partial")
    }

    func testRepeatedBoundaryDoesNotDuplicateOrClearNewPartial() {
        var buffer = SpeechTranscriptBuffer()
        buffer.receive(update("Hello", start: 0.2, duration: 1))
        buffer.receive(update("Hello", start: 0.2, duration: 1))
        XCTAssertEqual(buffer.text, "Hello")
        buffer.receive(update("Next sentence"))
        buffer.receive(update("Hello.", start: 0.2, duration: 1))
        XCTAssertEqual(buffer.text, "Hello. Next sentence")
    }

    func testSameWordsSpokenAgainAreNotDiscardedAsDuplicateCallback() {
        var buffer = SpeechTranscriptBuffer()
        buffer.receive(update("Go.", start: 0.3, duration: 0.7))
        buffer.receive(update("Go."))
        XCTAssertEqual(buffer.text, "Go. Go.")
        buffer.receive(update("Go.", start: 4, duration: 0.8))
        buffer.receive(update("Go.", isFinal: true))
        XCTAssertEqual(buffer.text, "Go. Go.")
        buffer.receive(update("Go. Go. Again."))
        XCTAssertEqual(buffer.text, "Go. Go. Go. Go. Again.")
    }

    func testCumulativeResultsReplaceCoveredUtterancesWithoutDuplication() {
        var buffer = SpeechTranscriptBuffer()
        buffer.receive(update("First.", start: 0.2, duration: 1))
        buffer.receive(update("Second"))
        XCTAssertEqual(buffer.text, "First. Second")
        buffer.receive(update("First. Second.", start: 0.2, duration: 5, isFinal: true))
        XCTAssertEqual(buffer.text, "First. Second.")
    }

    func testSingleUtteranceRevisionsRemainReplaceableUntilCompletion() {
        var buffer = SpeechTranscriptBuffer()
        buffer.receive(update("Open the setting"))
        buffer.receive(update("Open Settings"))
        buffer.receive(update("Open Settings.", start: 0.1, duration: 2, isFinal: true))
        XCTAssertEqual(buffer.text, "Open Settings.")
        buffer = SpeechTranscriptBuffer()
        buffer.receive(update("A new recording"))
        XCTAssertEqual(buffer.text, "A new recording")
    }

    private func update(_ text: String, start: TimeInterval? = nil, duration: TimeInterval = 0,
                        isFinal: Bool = false) -> SpeechInputCallbacks.RecognitionUpdate {
        .init(text: text, isFinal: isFinal, hasError: false,
              completedRange: start.flatMap { .init(start: $0, duration: duration) })
    }
}

