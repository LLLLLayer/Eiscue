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

    private(set) var state: State = .idle
    private(set) var transcript = ""
    private(set) var errorMessage: String?
    var isBusy: Bool { state != .idle }
    var isRecording: Bool { state == .recording }
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
    @ObservationIgnored private var onTranscript: (@MainActor (String) -> Void)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?
    @ObservationIgnored private var recordingTimeout: Task<Void, Never>?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var pipe: SpeechAudioPipe?
    @ObservationIgnored private var hasTap = false
    @ObservationIgnored private var ownsAudioSession = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
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

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        startTask?.cancel()
        finishTimeout?.cancel()
        recordingTimeout?.cancel()
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        pipe?.endAudio()
        recognitionTask?.cancel()
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func toggle(locale: Locale = .current, onTranscript: @escaping @MainActor (String) -> Void) {
        if isBusy { stop() }
        else { begin(mode: .toggle, locale: locale, onTranscript: onTranscript) }
    }

    func beginHold(locale: Locale = .current, onTranscript: @escaping @MainActor (String) -> Void) {
        if isBusy { stop(); return }
        begin(mode: .hold, locale: locale, onTranscript: onTranscript)
    }

    /// Also cancels pending permission work: releasing before authorization
    /// completes can never start the microphone later.
    func endHold() {
        guard gate.mode == .hold else { return }
        stop()
    }

    func stop() {
        guard let token = gate.token else { return }
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
        clearSession()
        transcript = ""
        errorMessage = nil
    }

    func clearError() { errorMessage = nil }

    private func begin(mode: SpeechInputSessionGate.Mode, locale: Locale,
                       onTranscript: @escaping @MainActor (String) -> Void) {
        guard UIApplication.shared.applicationState != .background,
              let token = gate.begin(mode: mode) else { return }
        self.onTranscript = onTranscript
        transcript = ""
        errorMessage = nil
        state = .requestingPermission
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.authorize()
                try Task.checkCancellation()
                guard self.gate.accepts(token), UIApplication.shared.applicationState != .background else { return }
                self.state = .preparing
                try self.startRecognition(locale: locale, token: token)
            } catch is CancellationError {
                // Stop/cancel already invalidated the session and cleared state.
            } catch {
                guard self.gate.accepts(token) else { return }
                self.fail(error as? Failure ?? .unavailable)
            }
        }
    }

    private func authorize() async throws {
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
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: SpeechInputCallbacks.audioTap(pipe: pipe))
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: SpeechInputCallbacks.recognition { [weak self] update in
            guard let self, self.gate.accepts(token) else { return }
            if let text = update.text { self.transcript = text }
            if update.isFinal { self.complete(token: token) }
            else if update.hasError {
                if self.state == .finishing || !self.transcript.isEmpty { self.complete(token: token) }
                else { self.fail(.unavailable) }
            }
        })
        engine.prepare()
        try engine.start()
        state = .recording
        // Apple's short-dictation API has a per-request duration limit.
        recordingTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(55)) } catch { return }
            guard self?.gate.accepts(token) == true else { return }
            self?.stop()
        }
    }

    private func stopForInterruption() {
        guard let token = gate.token else { return }
        // Release the microphone synchronously; never keep recording while
        // backgrounded, interrupted, or after an audio route reconfiguration.
        if state == .recording || state == .finishing { complete(token: token) }
        else { cancel() }
    }

    private func complete(token: UUID) {
        guard gate.accepts(token) else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let deliver = onTranscript
        clearSession()
        if text.isEmpty { errorMessage = Failure.noSpeech.localizedDescription }
        else { deliver?(text) }
    }

    private func fail(_ failure: Failure) {
        clearSession()
        errorMessage = failure.localizedDescription
    }

    private func stopAudio() {
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
        state = .idle
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

/// These Objective-C APIs do not annotate their blocks as Sendable. Creating
/// their closures in the controller would inherit MainActor and trap before
/// the callback body runs on a Speech or real-time audio queue. Keep the actual
/// production callbacks explicitly nonisolated and Sendable.
enum SpeechInputCallbacks {
    struct RecognitionUpdate: Sendable, Equatable {
        let text: String?
        let isFinal: Bool
        let hasError: Bool
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
            let update = RecognitionUpdate(text: result?.bestTranscription.formattedString,
                                           isFinal: result?.isFinal == true, hasError: error != nil)
            Task { @MainActor in onUpdate(update) }
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
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var ended = false
    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { if !ended { request.append(buffer) } }
    }
    func endAudio() {
        lock.withLock {
            guard !ended else { return }
            ended = true
            request.endAudio()
        }
    }
}
