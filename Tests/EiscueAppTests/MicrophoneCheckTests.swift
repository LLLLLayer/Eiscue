import AVFAudio
import XCTest
@testable import Eiscue

@MainActor
final class MicrophoneCheckTests: XCTestCase {
    func testSignalResultRequiresFiniteNonzeroSamplesAndReturnsAfterTeardown() async {
        for (samples, expected) in [
            (nil, MicrophoneCheckController.Result.noSignal),
            ([Float.zero, 0], .noSignal),
            ([Float.nan, .infinity], .noSignal),
            ([Float(0.000001), 0], .signalDetected),
            ([Float(-0.25), 0.25], .signalDetected)
        ] as [([Float]?, MicrophoneCheckController.Result)] {
            let fixture = MicrophoneCheckFixture()
            fixture.samples = samples
            let controller = fixture.controller()
            let result = await controller.check()
            XCTAssertEqual(result, expected)
            XCTAssertEqual(fixture.events, ["permission", "start", "stop"])
            XCTAssertFalse(controller.isChecking)
            XCTAssertEqual(controller.level, 0)
        }
    }

    func testDeniedPermissionDoesNotConfigureAudio() async {
        let fixture = MicrophoneCheckFixture()
        fixture.permission = false
        let controller = fixture.controller()
        let result = await controller.check()
        XCTAssertEqual(result, .permissionDenied)
        XCTAssertEqual(fixture.events, ["permission"])
        XCTAssertFalse(controller.isChecking)
    }

    func testCancelDuringPermissionReturnsPromptlyAndRejectsLatePermission() async throws {
        let fixture = MicrophoneCheckFixture()
        fixture.permission = nil
        let controller = fixture.controller()
        let first = Task { await controller.check() }
        try await waitUntil { fixture.permissionCallbacks.count == 1 }
        controller.cancel()
        let cancelled = await first.value
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertFalse(controller.isChecking)

        let second = Task { await controller.check() }
        try await waitUntil { fixture.permissionCallbacks.count == 2 }
        fixture.permissionCallbacks[0](true)
        fixture.permissionCallbacks[1](false)
        let denied = await second.value
        XCTAssertEqual(denied, .permissionDenied)
        XCTAssertEqual(fixture.events, ["permission", "permission"], "Old authorization must not start capture.")
    }

    func testCancellingAwaitingTaskAlsoCancelsPendingPermission() async throws {
        let fixture = MicrophoneCheckFixture()
        fixture.permission = nil
        let controller = fixture.controller()
        let task = Task { await controller.check() }
        try await waitUntil { controller.isChecking }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(controller.isChecking)
        XCTAssertEqual(fixture.events, ["permission"])
    }

    func testCancelStopsActiveCaptureBeforeReturningAndResetsLevel() async throws {
        let fixture = MicrophoneCheckFixture()
        fixture.duration = .seconds(5); fixture.samples = [0.25, -0.25]
        let controller = fixture.controller()
        let task = Task { await controller.check() }
        try await waitUntil { controller.level > 0 }
        controller.cancel()
        XCTAssertEqual(fixture.events.last, "stop")
        XCTAssertFalse(controller.isChecking)
        XCTAssertEqual(controller.level, 0)
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        controller.cancel()
        XCTAssertEqual(fixture.events.filter { $0 == "stop" }.count, 1)
    }

    func testMissingNewBuffersCannotLeaveAStaleLevel() async throws {
        let fixture = MicrophoneCheckFixture()
        fixture.duration = .seconds(5); fixture.samples = [0.25, -0.25]
        let controller = fixture.controller()
        let task = Task { await controller.check() }
        defer { controller.cancel() }
        try await waitUntil { controller.level > 0 }
        try await waitUntil { controller.level == 0 }
        controller.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }

    func testOverlappingCheckDoesNotReplaceActivePermissionRequest() async throws {
        let fixture = MicrophoneCheckFixture()
        fixture.permission = nil
        let controller = fixture.controller()
        let first = Task { await controller.check() }
        try await waitUntil { controller.isChecking }
        let overlapping = await controller.check()
        XCTAssertEqual(overlapping, .unavailable)
        XCTAssertEqual(fixture.permissionCallbacks.count, 1)
        XCTAssertTrue(controller.isChecking)
        controller.cancel()
        let result = await first.value
        XCTAssertEqual(result, .cancelled)
    }

    func testStartupAndTeardownFailuresNeverReportSuccessfulSignal() async {
        for failsStart in [false, true] {
            let fixture = MicrophoneCheckFixture()
            fixture.samples = [0.25]
            fixture.failsStart = failsStart; fixture.failsStop = !failsStart
            let controller = fixture.controller()
            let result = await controller.check()
            XCTAssertEqual(result, .unavailable)
            XCTAssertEqual(fixture.events, ["permission", "start", "stop"])
            XCTAssertFalse(controller.isChecking)
        }
    }

    func testBackgroundDuringPermissionOrCaptureNeverRestartsAudio() async throws {
        for duringCapture in [false, true] {
            let fixture = MicrophoneCheckFixture()
            fixture.permission = duringCapture ? true : nil
            fixture.duration = .seconds(5)
            let controller = fixture.controller()
            let task = Task { await controller.check() }
            try await waitUntil { duringCapture ? fixture.events.contains("start") : controller.isChecking }
            fixture.foreground = false
            if !duringCapture { fixture.permissionCallbacks[0](true) }
            let result = await task.value
            XCTAssertEqual(result, .cancelled)
            XCTAssertEqual(fixture.events, duringCapture ? ["permission", "start", "stop"] : ["permission"])
            fixture.foreground = true
            XCTAssertFalse(controller.isChecking)
        }
    }

    func testStoppedEngineOrChangedInputRouteMakesCheckUnavailable() async throws {
        let fixture = MicrophoneCheckFixture()
        fixture.duration = .seconds(5)
        let controller = fixture.controller()
        let task = Task { await controller.check() }
        try await waitUntil { fixture.events.contains("start") }
        fixture.captureActive = false
        let result = await task.value
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(fixture.events.last, "stop")
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        XCTFail("The synthetic microphone check did not reach the expected state.")
        throw NSError(domain: "MicrophoneCheckTests", code: 1)
    }
}

final class MicrophoneCheckMeterTests: XCTestCase {
    func testNoBuffersUnreadableBuffersAndSilenceAreNotSignal() throws {
        let empty = MicrophoneCheckMeter()
        XCTAssertNil(empty.consumeLevel())
        XCTAssertFalse(empty.end())
        let unreadable = MicrophoneCheckMeter()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        unreadable.append(buffer)
        XCTAssertNil(unreadable.consumeLevel())
        XCTAssertFalse(unreadable.end())
    }

    func testMeterReadsAllChannelsForInterleavedAndPlanarPCM() throws {
        for interleaved in [false, true] {
            let meter = MicrophoneCheckMeter()
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                    channels: 2, interleaved: interleaved))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
            buffer.frameLength = 4
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<4 {
                if interleaved { channels[0][frame * 2] = 0; channels[0][frame * 2 + 1] = 0.25 }
                else { channels[0][frame] = 0; channels[1][frame] = 0.25 }
            }
            meter.append(buffer)
            XCTAssertEqual(try XCTUnwrap(meter.consumeLevel()), sqrt(0.03125), accuracy: 0.0001)
            XCTAssertNil(meter.consumeLevel())
            XCTAssertTrue(meter.end(), "Finite input on a non-primary channel is still microphone signal.")
        }
    }

    @MainActor func testProductionPermissionCallbackHopsFromBackgroundToMainActor() async {
        let granted = await withCheckedContinuation { continuation in
            let callback = MicrophoneCheckCallbacks.permission { granted in
                MainActor.assertIsolated()
                continuation.resume(returning: granted)
            }
            DispatchQueue.global(qos: .default).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                callback(true)
            }
        }
        XCTAssertTrue(granted)
    }

    @MainActor func testProductionAudioCallbackAcceptsBackgroundPCMAndRejectsLateBuffers() async throws {
        let meter = MicrophoneCheckMeter()
        let callback = MicrophoneCheckCallbacks.audioTap(meter: meter)
        let delivered = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
                    continuation.resume(returning: false); return
                }
                buffer.frameLength = 4
                buffer.floatChannelData?[0].initialize(repeating: 0, count: 4)
                callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
                meter.end()
                buffer.floatChannelData?[0].update(repeating: 0.5, count: 4)
                callback(buffer, AVAudioTime(sampleTime: 4, atRate: 16_000))
                continuation.resume(returning: true)
            }
        }
        XCTAssertTrue(delivered)
        XCTAssertFalse(meter.end(), "A late buffer must not turn a stopped check into success.")
        XCTAssertNil(meter.consumeLevel())
    }

    func testNormalizedLevelIsFiniteAndBounded() {
        for value in [Float.zero, -1, .nan, .infinity] {
            XCTAssertEqual(MicrophoneCheckMeter.normalizedLevel(rms: value), 0)
        }
        XCTAssertGreaterThan(MicrophoneCheckMeter.normalizedLevel(rms: 0.1), 0)
        XCTAssertLessThan(MicrophoneCheckMeter.normalizedLevel(rms: 0.1), 1)
        XCTAssertEqual(MicrophoneCheckMeter.normalizedLevel(rms: 1), 1)
    }
}

@MainActor
private final class MicrophoneCheckFixture {
    var events: [String] = []
    var permission: Bool? = true
    var permissionCallbacks: [@Sendable (Bool) -> Void] = []
    var samples: [Float]?
    var duration = Duration.zero
    var foreground = true
    var captureActive = true
    var failsStart = false
    var failsStop = false

    func controller() -> MicrophoneCheckController {
        MicrophoneCheckController(dependencies: .init(requestPermission: { [self] callback in
            events.append("permission"); permissionCallbacks.append(callback)
            if let permission { callback(permission) }
        }, startCapture: { [self] meter in
            events.append("start")
            if failsStart { throw NSError(domain: "MicrophoneCheckFixture", code: 1) }
            if let samples {
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
                buffer.frameLength = AVAudioFrameCount(samples.count)
                let data = try XCTUnwrap(buffer.floatChannelData?[0])
                for (index, value) in samples.enumerated() { data[index] = value }
                meter.append(buffer)
            }
        }, stopCapture: { [self] in
            events.append("stop")
            if failsStop { throw NSError(domain: "MicrophoneCheckFixture", code: 2) }
        }, isForeground: { [self] in foreground }, isCaptureActive: { [self] in captureActive }, captureDuration: duration))
    }
}
