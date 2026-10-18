import AVFAudio
import Foundation
import Observation
import Speech
import UIKit

/// Short, on-device dictation. Audio is streamed in memory and never saved.
/// Only a completed utterance is delivered; this controller never sends a chat.
@MainActor
@Observable
final class SpeechInputController {
    enum State: Equatable { case idle, requestingPermission, preparing, recording, finishing }
    struct Dependencies {
        var authorize: @MainActor () async throws -> Void
        var startRecognition: @MainActor (Locale, UUID) throws -> Void
        var isForeground: @MainActor () -> Bool
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    private(set) var errorMessage: String?
    private(set) var capture = SpeechAudioPipe.Snapshot()
    @ObservationIgnored let audioMeter = SpeechAudioMeter()
    var accessibilityStatus: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--speech-diagnostics") {
            return "state=\(state) buffers=\(capture.buffers) frames=\(capture.frames) signal=\(capture.hasInput) recognized=\(!transcript.isEmpty)"
        }
        #endif
        return statusText
    }
    var isBusy: Bool { state != .idle }
    var isRecording: Bool { state == .recording }
    var isHoldSession: Bool { isBusy && gate.mode == .hold }
    var statusText: String {
        switch state {
        case .idle: String(localized: "speech.hint", table: "Speech")
        case .requestingPermission: String(localized: "speech.permissions", table: "Speech")
        case .preparing: String(localized: "speech.preparing", table: "Speech")
        case .recording: String(localized: "speech.listening", table: "Speech")
        case .finishing: String(localized: "speech.finishing", table: "Speech")
        }
    }

    @ObservationIgnored private var gate = SpeechInputSessionGate()
    @ObservationIgnored private var transcriptBuffer = SpeechTranscriptBuffer()
    @ObservationIgnored private var onTranscript: (@MainActor (String) -> Void)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?
    @ObservationIgnored private var recordingTimeout: Task<Void, Never>?
    @ObservationIgnored private var captureMonitor: Task<Void, Never>?
    @ObservationIgnored private let resources = SpeechInputResources()
    private var recognizer: SFSpeechRecognizer? {
        get { resources.state.recognizer } set { resources.state.recognizer = newValue }
    }
    private var recognitionTask: SFSpeechRecognitionTask? {
        get { resources.state.recognitionTask } set { resources.state.recognitionTask = newValue }
    }
    private var engine: AVAudioEngine? {
        get { resources.state.engine } set { resources.state.engine = newValue }
    }
    private var pipe: SpeechAudioPipe? {
        get { resources.state.pipe } set { resources.state.pipe = newValue }
    }
    private var hasTap: Bool {
        get { resources.state.hasTap } set { resources.state.hasTap = newValue }
    }
    private var ownsAudioSession: Bool {
        get { resources.state.ownsAudioSession } set { resources.state.ownsAudioSession = newValue }
    }
    private var observers: [NSObjectProtocol] {
        get { resources.state.observers } set { resources.state.observers = newValue }
    }
    @ObservationIgnored private let dependencies: Dependencies?
    #if DEBUG
    @ObservationIgnored private var captureDiagnostics: [[String: Any]] = []
    #endif

    init(dependencies: Dependencies? = nil) {
        var configuredDependencies = dependencies
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if configuredDependencies == nil, arguments.contains("--ui-testing"),
           arguments.contains("--speech-recording-fixture") ||
            (arguments.contains("--local-device-ready-fixture") && arguments.contains("--speech-device-ready-fixture")) {
            configuredDependencies = Dependencies(authorize: {}, startRecognition: { _, _ in },
                isForeground: { UIApplication.shared.applicationState != .background })
        }
        #endif
        self.dependencies = configuredDependencies
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForInterruption() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            if began { MainActor.assumeIsolated { self?.stopForInterruption() } }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: nil, queue: .main) { [weak self] notification in
            let changedEngine = (notification.object as? AVAudioEngine).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard self?.isRecording == true,
                      self?.engine.map(ObjectIdentifier.init) == changedEngine else { return }
                self?.stopForInterruption()
            }
        })
    }

    // Isolated deinit crashes in iOS 26's TaskLocal runtime when SwiftUI releases
    // this object outside a Swift task (swiftlang/swift#88036). Keep teardown
    // synchronous on the releasing thread; these APIs require no actor hop.
    nonisolated deinit {
        startTask?.cancel()
        finishTimeout?.cancel()
        recordingTimeout?.cancel()
        captureMonitor?.cancel()
    }

    func toggle(locale: Locale = .current, beforeRecording: @escaping @MainActor () async throws -> Void = {},
                onTranscript: @escaping @MainActor (String) -> Void) {
        if isBusy { stop() }
        else { begin(mode: .toggle, locale: locale, beforeRecording: beforeRecording, onTranscript: onTranscript) }
    }

    func beginHold(locale: Locale = .current, beforeRecording: @escaping @MainActor () async throws -> Void = {},
                   onTranscript: @escaping @MainActor (String) -> Void) {
        if isBusy { stop(); return }
        begin(mode: .hold, locale: locale, beforeRecording: beforeRecording, onTranscript: onTranscript)
    }

    /// Also cancels pending permission work: releasing before authorization
    /// completes can never start the microphone later.
    func endHold() {
        guard gate.mode == .hold else { return }
        recordCaptureDiagnostic("hold-released")
        stop()
    }

    func stop() {
        guard let token = gate.token else { return }
        recordCaptureDiagnostic("stop")
        guard state == .recording else {
            if state != .finishing { cancel() }
            return
        }
        state = .finishing
        stopAudio()
        recognitionTask?.finish()
        finishTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.complete(token: token)
        }
    }

    /// Explicit cancellation discards only this utterance, never the typed draft.
    func cancel() {
        recordCaptureDiagnostic("cancel")
        clearSession()
        transcript = ""
        errorMessage = nil
        capture = .init()
    }

    func clearError() { errorMessage = nil }

    private var isForeground: Bool { dependencies?.isForeground() ?? (UIApplication.shared.applicationState != .background) }

    private func begin(mode: SpeechInputSessionGate.Mode, locale: Locale,
                       beforeRecording: @escaping @MainActor () async throws -> Void = {},
                       onTranscript: @escaping @MainActor (String) -> Void) {
        guard isForeground, let token = gate.begin(mode: mode) else { return }
        self.onTranscript = onTranscript
        transcriptBuffer = SpeechTranscriptBuffer()
        capture = .init()
        audioMeter.reset()
        transcript = ""
        errorMessage = nil
        state = .requestingPermission
        #if DEBUG
        captureDiagnostics.removeAll()
        #endif
        recordCaptureDiagnostic("begin")
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var isRunningPreparationHook = false
            do {
                try await self.authorize()
                self.recordCaptureDiagnostic("authorized")
                try Task.checkCancellation()
                guard self.gate.accepts(token) else { return }
                guard self.isForeground else { self.cancel(); return }
                self.state = .preparing
                isRunningPreparationHook = true
                self.recordCaptureDiagnostic("device-preparation-started")
                try await beforeRecording()
                isRunningPreparationHook = false
                try Task.checkCancellation()
                guard self.gate.accepts(token) else { return }
                guard self.isForeground else { self.cancel(); return }
                self.recordCaptureDiagnostic("device-preparation-finished")
                try self.startRecognition(locale: locale, token: token)
            } catch is CancellationError {
                if self.gate.accepts(token) { self.cancel() }
            } catch {
                guard self.gate.accepts(token) else { return }
                self.recordCaptureDiagnostic("startup-error", error: error as NSError)
                if isRunningPreparationHook {
                    self.clearSession()
                    self.errorMessage = error.localizedDescription
                } else { self.fail(error as? Failure ?? .unavailable) }
            }
        }
    }

    private func authorize() async throws {
        if let dependencies { try await dependencies.authorize(); return }
        let authorization: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization(SpeechInputCallbacks.authorization(continuation))
            }
        } else { authorization = SFSpeechRecognizer.authorizationStatus() }
        try Task.checkCancellation()
        switch authorization {
        case .authorized: break
        case .restricted: throw Failure.restricted
        default: throw Failure.speechDenied
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        try Task.checkCancellation()
        guard granted else { throw Failure.microphoneDenied }
    }

    private func startRecognition(locale: Locale, token: UUID) throws {
        if let dependencies {
            try dependencies.startRecognition(locale, token)
            state = .recording
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw Failure.unsupportedLocale }
        if let requestedLanguage = locale.language.languageCode,
           recognizer.locale.language.languageCode != requestedLanguage { throw Failure.unsupportedLocale }
        guard recognizer.supportsOnDeviceRecognition else { throw Failure.unsupportedLocale }
        guard recognizer.isAvailable else { throw Failure.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.recognizer = recognizer
        let pipe = SpeechAudioPipe(request: request)
        self.pipe = pipe

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        ownsAudioSession = true
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.microphoneUnavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: SpeechInputCallbacks.audioTap(pipe: pipe))
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: SpeechInputCallbacks.recognition { [weak self] update in
            guard let self, self.gate.accepts(token) else { return }
            if update.hasError {
                self.recordCaptureDiagnostic("recognition-error", error: NSError(
                    domain: update.errorDomain ?? "Speech", code: update.errorCode ?? 0))
            }
            guard pipe.snapshot.hasInput else {
                if update.hasError || update.isFinal { self.fail(.microphoneUnavailable) }
                return
            }
            self.transcriptBuffer.receive(update)
            self.transcript = self.transcriptBuffer.text
            if update.isFinal { self.complete(token: token) }
            else if update.hasError {
                if self.state == .finishing || !self.transcript.isEmpty { self.complete(token: token) }
                else { self.fail(.unavailable) }
            }
        })
        engine.prepare()
        try engine.start()
        recordCaptureDiagnostic("engine-started")
        captureMonitor = Task { @MainActor [weak self] in
            var tick = 0
            let deadline = ContinuousClock.now + .seconds(4)
            while !Task.isCancelled {
                guard let self, self.gate.accepts(token) else { return }
                let capture = pipe.snapshot
                self.audioMeter.append(rms: pipe.consumeLevel())
                if tick % 4 == 0 { self.capture = capture }
                // Remote-control policy can deliver valid buffers containing
                // only zeroes. Buffer arrival alone doesn't mean the mic works.
                if capture.hasInput, self.state == .preparing { self.state = .recording }
                if self.state == .preparing, ContinuousClock.now >= deadline {
                    self.fail(.microphoneUnavailable)
                    return
                }
                if tick % 20 == 0 { self.recordCaptureDiagnostic("capture") }
                tick += 1
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        // Apple's short-dictation API has a per-request duration limit.
        recordingTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(55)) } catch { return }
            guard self?.gate.accepts(token) == true else { return }
            self?.stop()
        }
    }

    private func stopForInterruption() {
        guard let token = gate.token else { return }
        recordCaptureDiagnostic("interrupted")
        // Release the microphone synchronously; never keep recording while
        // backgrounded, interrupted, or after an audio route reconfiguration.
        if state == .recording || state == .finishing { complete(token: token) }
        else { cancel() }
    }

    private func complete(token: UUID) {
        guard gate.accepts(token) else { return }
        recordCaptureDiagnostic("completed")
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let deliver = onTranscript
        clearSession()
        if text.isEmpty { errorMessage = Failure.noSpeech.localizedDescription }
        else { deliver?(text) }
    }

    private func fail(_ failure: Failure) {
        recordCaptureDiagnostic("failed-\(failure)")
        clearSession()
        errorMessage = failure.localizedDescription
    }

    private func stopAudio() {
        captureMonitor?.cancel(); captureMonitor = nil
        audioMeter.reset()
        if let pipe { capture = pipe.snapshot }
        recordingTimeout?.cancel(); recordingTimeout = nil
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        pipe?.endAudio()
        engine = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private func clearSession() {
        gate.invalidate()
        startTask?.cancel(); startTask = nil
        finishTimeout?.cancel(); finishTimeout = nil
        stopAudio()
        recognitionTask?.cancel(); recognitionTask = nil
        recognizer = nil; pipe = nil; onTranscript = nil
        transcriptBuffer = SpeechTranscriptBuffer()
        state = .idle
    }

    private func recordCaptureDiagnostic(_ stage: String, error: NSError? = nil) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--speech-diagnostics") else { return }
        let session = AVAudioSession.sharedInstance()
        let sample = pipe?.snapshot ?? capture
        let mode: String
        switch gate.mode {
        case .hold: mode = "hold"
        case .toggle: mode = "toggle"
        case nil: mode = "none"
        }
        var row: [String: Any] = [
            "stage": stage, "state": String(describing: state), "mode": mode, "time": Date().timeIntervalSince1970,
            "speechPermission": SFSpeechRecognizer.authorizationStatus().rawValue,
            "microphonePermission": AVAudioApplication.shared.recordPermission.rawValue,
            "inputMuted": AVAudioApplication.shared.isInputMuted,
            "engineRunning": engine?.isRunning == true,
            "appState": UIApplication.shared.applicationState.rawValue,
            "inputPorts": session.currentRoute.inputs.map { $0.portType.rawValue },
            "sampleRate": session.sampleRate, "channels": session.inputNumberOfChannels,
            "buffers": sample.buffers, "frames": sample.frames,
            "signal": sample.hasInput, "peak": sample.peak.isFinite ? sample.peak : 0,
            "bufferFormat": sample.format, "readableSamples": sample.readableSamples,
            "recognized": !transcript.isEmpty,
            "locale": recognizer?.locale.identifier ?? Locale.current.identifier
        ]
        if let error { row["errorDomain"] = error.domain; row["errorCode"] = error.code }
        captureDiagnostics.append(row)
        if captureDiagnostics.count > 64 { captureDiagnostics.removeFirst() }
        guard let data = try? JSONSerialization.data(withJSONObject: captureDiagnostics, options: .sortedKeys) else { return }
        let url = URL.documentsDirectory.appendingPathComponent("SpeechCaptureDiagnostic.json")
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    private enum Failure: LocalizedError {
        case speechDenied, microphoneDenied, restricted, unsupportedLocale, unavailable, microphoneUnavailable, noSpeech
        var errorDescription: String? {
            switch self {
            case .speechDenied: String(localized: "speech.error.permission", table: "Speech")
            case .microphoneDenied: String(localized: "speech.error.microphonePermission", table: "Speech")
            case .restricted: String(localized: "speech.error.restricted", table: "Speech")
            case .unsupportedLocale: String(localized: "speech.error.locale", table: "Speech")
            case .unavailable: String(localized: "speech.error.unavailable", table: "Speech")
            case .microphoneUnavailable: String(localized: "speech.error.microphoneUnavailable", table: "Speech")
            case .noSpeech: String(localized: "speech.error.noSpeech", table: "Speech")
            }
        }
    }
}

/// Only the controller owns this box. Live state is accessed on MainActor; its
/// final release has exclusive access and performs thread-independent teardown.
/// Keeping non-Sendable AV/Speech references here avoids transferring them to a
/// task or marking individual controller fields nonisolated(unsafe).
private final class SpeechInputResources: @unchecked Sendable {
    struct State {
        var recognizer: SFSpeechRecognizer?
        var recognitionTask: SFSpeechRecognitionTask?
        var engine: AVAudioEngine?
        var pipe: SpeechAudioPipe?
        var hasTap = false
        var ownsAudioSession = false
        var observers: [NSObjectProtocol] = []
    }
    private var storage = State()
    @MainActor var state: State {
        get { storage } set { storage = newValue }
    }

    deinit {
        for observer in storage.observers { NotificationCenter.default.removeObserver(observer) }
        storage.engine?.stop()
        if storage.hasTap { storage.engine?.inputNode.removeTap(onBus: 0) }
        storage.pipe?.endAudio()
        storage.recognitionTask?.cancel()
        if storage.ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// These Objective-C APIs do not annotate their blocks as Sendable. Creating
/// their closures in the controller would inherit MainActor and trap before
/// the callback body runs on a Speech or real-time audio queue. Keep the actual
/// production callbacks explicitly nonisolated and Sendable.
enum SpeechInputCallbacks {
    struct RecognitionUpdate: Sendable, Equatable {
        let text: String?
        let isFinal: Bool
        let hasError: Bool
        var completedRange: SpeechTranscriptBuffer.AudioRange? = nil
        var errorDomain: String? = nil
        var errorCode: Int? = nil
    }

    nonisolated static func authorization(
        _ continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>
    ) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { @Sendable status in continuation.resume(returning: status) }
    }

    nonisolated static func audioTap(pipe: SpeechAudioPipe) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable buffer, _ in pipe.append(buffer) }
    }

    nonisolated static func recognition(
        onUpdate: @escaping @MainActor @Sendable (RecognitionUpdate) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { @Sendable result, error in
            // Speech objects stay on their callback queue; only values cross.
            let range = (result?.speechRecognitionMetadata).flatMap {
                SpeechTranscriptBuffer.AudioRange(start: $0.speechStartTimestamp, duration: $0.speechDuration)
            }
            let update = RecognitionUpdate(text: result?.bestTranscription.formattedString,
                                           isFinal: result?.isFinal == true, hasError: error != nil,
                                           completedRange: range,
                                           errorDomain: (error as NSError?)?.domain,
                                           errorCode: (error as NSError?)?.code)
            Task { @MainActor in onUpdate(update) }
        }
    }
}

/// On-device recognition may close an utterance at a pause without ending the
/// request. Its next hypothesis then contains only the next utterance. Keep
/// those boundaries instead of replacing everything with each partial result.
struct SpeechTranscriptBuffer {
    struct AudioRange: Sendable, Equatable {
        let start: TimeInterval
        let end: TimeInterval
        init?(start: TimeInterval, duration: TimeInterval) {
            guard start.isFinite, duration.isFinite, start >= 0, duration > 0,
                  (start + duration).isFinite else { return nil }
            self.start = start; self.end = start + duration
        }
    }

    private struct Utterance {
        var text: String
        let range: AudioRange
    }
    private var completed: [Utterance] = []
    private var partial = ""

    var text: String {
        (completed.map(\.text) + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func receive(_ update: SpeechInputCallbacks.RecognitionUpdate) {
        guard let value = update.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            // Stopping after a pause can produce an empty final result.
            return
        }
        if let range = update.completedRange {
            if let index = completed.firstIndex(where: {
                abs($0.range.start - range.start) < 0.05 && abs($0.range.end - range.end) < 0.05
            }) {
                // A repeated boundary (including final punctuation corrections)
                // must neither append twice nor erase the next live utterance.
                completed[index].text = value
                return
            }
            if let last = completed.last, range.end < last.range.start { return }
            if let overlap = completed.firstIndex(where: { $0.range.end > range.start + 0.05 }) {
                // Some recognizers return the cumulative request at completion.
                completed.removeSubrange(overlap...)
            }
            completed.append(Utterance(text: value, range: range))
            partial = ""
        } else {
            if update.isFinal, partial.isEmpty, value == completed.last?.text { return }
            // Text prefixes are not utterance identities: users can repeat the
            // same words after a pause. Only timed results may replace history.
            partial = value
        }
    }
}

/// Identity gates delayed authorization, recognition, and timeout callbacks.
struct SpeechInputSessionGate {
    enum Mode { case toggle, hold }
    private(set) var token: UUID?
    private(set) var mode: Mode?
    mutating func begin(mode: Mode) -> UUID? {
        guard token == nil else { return nil }
        let token = UUID()
        self.token = token; self.mode = mode
        return token
    }
    func accepts(_ token: UUID) -> Bool { self.token == token }
    mutating func invalidate() { token = nil; mode = nil }
}

/// The audio callback is outside MainActor. Serialize append/end so a late
/// buffer after a stop cannot reopen or extend a recognition request.
final class SpeechAudioPipe: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var buffers = 0
        var frames: UInt64 = 0
        var peak: Float = 0
        var format: UInt = 0
        var readableSamples = false
        var hasInput: Bool { readableSamples && peak > 0 }
    }
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var ended = false
    private var captured = Snapshot()
    private var levelEnergy: Double = 0
    private var levelSamples = 0
    var snapshot: Snapshot { lock.withLock { captured } }
    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !ended else { return }
            captured.buffers += 1
            captured.frames += UInt64(buffer.frameLength)
            captured.format = buffer.format.commonFormat.rawValue
            if let samples = buffer.floatChannelData?[0] {
                captured.readableSamples = true
                for index in 0..<Int(buffer.frameLength) {
                    measure(samples[index * buffer.stride])
                }
            } else if let samples = buffer.int16ChannelData?[0] {
                captured.readableSamples = true
                for index in 0..<Int(buffer.frameLength) {
                    measure(Float(samples[index * buffer.stride]) / 32_768)
                }
            } else if let samples = buffer.int32ChannelData?[0] {
                captured.readableSamples = true
                for index in 0..<Int(buffer.frameLength) {
                    measure(Float(samples[index * buffer.stride]) / 2_147_483_648)
                }
            }
            request.append(buffer)
        }
    }
    /// Drain one UI interval, independently of the cumulative capture evidence.
    /// Empty windows are distinct from sampled silence. No buffers or individual
    /// audio samples are retained for visualization.
    func consumeLevel() -> Float? {
        lock.withLock {
            defer { levelEnergy = 0; levelSamples = 0 }
            guard levelSamples > 0 else { return nil }
            return Float(sqrt(levelEnergy / Double(levelSamples)))
        }
    }
    private func measure(_ sample: Float) {
        guard sample.isFinite else { return }
        captured.peak = max(captured.peak, abs(sample))
        let value = Double(sample)
        levelEnergy += value * value
        levelSamples += 1
    }
    func endAudio() {
        lock.withLock {
            guard !ended else { return }
            ended = true
            request.endAudio()
        }
    }
}

/// Only the small waveform view observes this 20 Hz projection. Keeping it
/// separate from the controller prevents audio levels from rebuilding history.
@MainActor
@Observable
final class SpeechAudioMeter {
    private(set) var levels = Array(repeating: Double.zero, count: 40)
    private(set) var level: Double = 0
    @ObservationIgnored private var lastSampleAt: ContinuousClock.Instant?

    func append(rms: Float?, at now: ContinuousClock.Instant = ContinuousClock.now) {
        guard let rms else {
            // The UI clock can outrun an audio callback. Hold the most recent
            // measurement briefly, but never leave stalled input onscreen.
            if let lastSampleAt, now - lastSampleAt >= .milliseconds(250) { reset() }
            return
        }
        let input = Self.normalizedLevel(rms: rms)
        guard input > 0 else { reset(); return }
        lastSampleAt = now
        level += (input - level) * (input > level ? 0.7 : 0.3)
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        lastSampleAt = nil
        guard level != 0 || levels.contains(where: { $0 != 0 }) else { return }
        level = 0
        levels = Array(repeating: 0, count: levels.count)
    }

    nonisolated static func normalizedLevel(rms: Float) -> Double {
        guard rms.isFinite, rms > 0.001 else { return 0 }
        return min(1, max(0, (20 * log10(Double(rms)) + 60) / 54))
    }
}
