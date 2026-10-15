import AVFAudio
import Foundation
import Observation
import UIKit

/// A bounded check for finite, nonzero microphone PCM, not speech or audio quality.
/// Audio is measured in memory; there is no recognizer, transcript, or recording.
@MainActor
@Observable
final class MicrophoneCheckController {
    enum Result: Equatable, Sendable { case signalDetected, noSignal, permissionDenied, unavailable, cancelled }
    struct Dependencies {
        var requestPermission: @MainActor (@escaping @Sendable (Bool) -> Void) -> Void
        var startCapture: @MainActor (MicrophoneCheckMeter) throws -> Void
        var stopCapture: @MainActor () throws -> Void
        var isForeground: @MainActor () -> Bool
        var isCaptureActive: @MainActor () -> Bool = { true }
        var captureDuration: Duration = .seconds(5)
    }

    private(set) var level: Double = 0
    private(set) var isChecking = false
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var completion: CheckedContinuation<Result, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var meter: MicrophoneCheckMeter?
    @ObservationIgnored private var attemptedCapture = false

    init(dependencies: Dependencies? = nil) {
        if let dependencies { self.dependencies = dependencies }
        else {
            let capture = MicrophoneCheckCapture()
            self.dependencies = Dependencies(
                requestPermission: { AVAudioApplication.requestRecordPermission(completionHandler: $0) },
                startCapture: { try capture.start(meter: $0) },
                stopCapture: { try capture.stop() },
                isForeground: { UIApplication.shared.applicationState != .background },
                isCaptureActive: { capture.isActive })
        }
    }

    isolated deinit {
        monitor?.cancel()
        meter?.end()
        if attemptedCapture { try? dependencies.stopCapture() }
        completion?.resume(returning: .cancelled)
    }

    /// Returns after capture has stopped and session teardown has been attempted.
    /// A teardown failure is unavailable, never a successful signal check.
    func check() async -> Result {
        guard !Task.isCancelled, dependencies.isForeground() else { return .cancelled }
        guard !isChecking else { return .unavailable }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancelled); return }
                token = id; completion = continuation
                level = 0; isChecking = true
                dependencies.requestPermission(MicrophoneCheckCallbacks.permission { [weak self] granted in
                    self?.permissionResolved(granted, token: id)
                })
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.cancelled, token: id) }
        }
    }

    /// The system permission sheet may remain, but its eventual reply cannot
    /// start capture or affect a subsequent check.
    func cancel() {
        guard let token else { return }
        finish(.cancelled, token: token)
    }

    private func permissionResolved(_ granted: Bool, token id: UUID) {
        guard token == id else { return }
        guard dependencies.isForeground() else { finish(.cancelled, token: id); return }
        guard granted else { finish(.permissionDenied, token: id); return }
        let meter = MicrophoneCheckMeter()
        self.meter = meter
        attemptedCapture = true
        do { try dependencies.startCapture(meter) }
        catch { finish(.unavailable, token: id); return }
        let duration = dependencies.captureDuration
        monitor = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + duration
            var lastSampleAt = ContinuousClock.now
            while !Task.isCancelled {
                guard let self, self.token == id else { return }
                guard self.dependencies.isForeground() else { self.finish(.cancelled, token: id); return }
                guard self.dependencies.isCaptureActive() else { self.finish(.unavailable, token: id); return }
                let now = ContinuousClock.now
                if let rms = meter.consumeLevel() {
                    let input = MicrophoneCheckMeter.normalizedLevel(rms: rms)
                    self.level = input == 0 ? 0 : self.level + (input - self.level) * 0.65
                    lastSampleAt = now
                } else if now - lastSampleAt >= .milliseconds(250) { self.level = 0 }
                if now >= deadline { self.finish(token: id); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    private func finish(_ requestedResult: Result? = nil, token id: UUID) {
        guard token == id else { return }
        token = nil
        monitor?.cancel(); monitor = nil
        let hasSignal = meter?.end() ?? false
        var result = requestedResult ?? (hasSignal ? .signalDetected : .noSignal)
        if attemptedCapture {
            do { try dependencies.stopCapture() }
            catch { result = .unavailable }
        }
        attemptedCapture = false; meter = nil
        level = 0; isChecking = false
        let continuation = completion; completion = nil
        continuation?.resume(returning: result)
    }
}

/// System callbacks must not inherit the controller's MainActor isolation.
enum MicrophoneCheckCallbacks {
    nonisolated static func permission(
        _ receive: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> @Sendable (Bool) -> Void {
        { @Sendable granted in Task { @MainActor in receive(granted) } }
    }

    nonisolated static func audioTap(meter: MicrophoneCheckMeter) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable buffer, _ in meter.append(buffer) }
    }
}

/// The realtime callback retains aggregate numbers only. End rejects late buffers.
final class MicrophoneCheckMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var hasSignal = false
    private var energy: Double = 0
    private var samples = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !ended else { return }
            let interleaved = buffer.format.isInterleaved
            for channel in 0..<Int(buffer.format.channelCount) {
                let pointer = interleaved ? 0 : channel, offset = interleaved ? channel : 0
                if let data = buffer.floatChannelData?[pointer] {
                    for frame in 0..<Int(buffer.frameLength) { measure(data[frame * buffer.stride + offset]) }
                } else if let data = buffer.int16ChannelData?[pointer] {
                    for frame in 0..<Int(buffer.frameLength) {
                        measure(Float(data[frame * buffer.stride + offset]) / 32_768)
                    }
                } else if let data = buffer.int32ChannelData?[pointer] {
                    for frame in 0..<Int(buffer.frameLength) {
                        measure(Float(data[frame * buffer.stride + offset]) / 2_147_483_648)
                    }
                }
            }
        }
    }

    private func measure(_ value: Float) {
        guard value.isFinite else { return }
        if value != 0 { hasSignal = true }
        energy += Double(value) * Double(value)
        samples += 1
    }

    func consumeLevel() -> Float? {
        lock.withLock {
            defer { energy = 0; samples = 0 }
            guard samples > 0 else { return nil }
            return Float(sqrt(energy / Double(samples)))
        }
    }

    @discardableResult func end() -> Bool {
        lock.withLock {
            ended = true
            energy = 0; samples = 0
            return hasSignal
        }
    }

    static func normalizedLevel(rms: Float) -> Double {
        guard rms.isFinite, rms > 0.001 else { return 0 }
        return min(1, max(0, (20 * log10(Double(rms)) + 60) / 54))
    }
}

@MainActor
private final class MicrophoneCheckCapture {
    private struct Configuration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let preferredInput: AVAudioSessionPortDescription?
    }
    private enum Failure: Error { case unavailable }
    private var engine: AVAudioEngine?
    private var hasTap = false
    private var configuration: Configuration?
    private var attemptedActivation = false
    var isActive: Bool {
        engine?.isRunning == true &&
            AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .builtInMic }
    }

    func start(meter: MicrophoneCheckMeter) throws {
        let session = AVAudioSession.sharedInstance()
        configuration = Configuration(category: session.category, mode: session.mode,
                                      options: session.categoryOptions, preferredInput: session.preferredInput)
        try session.setCategory(.record, mode: .measurement)
        attemptedActivation = true
        try session.setActive(true)
        guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw Failure.unavailable
        }
        try session.setPreferredInput(microphone)
        guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) else {
            throw Failure.unavailable
        }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: MicrophoneCheckCallbacks.audioTap(meter: meter))
        hasTap = true
        engine.prepare()
        try engine.start()
    }

    func stop() throws {
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        engine = nil
        let session = AVAudioSession.sharedInstance()
        var failure: (any Error)?
        if let configuration, attemptedActivation {
            do { try session.setPreferredInput(configuration.preferredInput) }
            catch { failure = error }
        }
        if attemptedActivation {
            do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
            catch { failure = error }
        }
        attemptedActivation = false
        if let configuration {
            do { try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options) }
            catch { failure = error }
        }
        configuration = nil
        if let failure { throw failure }
    }
}
