import Foundation
import XCTest
@testable import Eiscue

final class SpeechInputSessionGateTests: XCTestCase {
    func testOverlappingTapAndHoldCannotStartTwoSessions() throws {
        var gate = SpeechInputSessionGate()
        let token = try XCTUnwrap(gate.begin(mode: .toggle))
        XCTAssertNil(gate.begin(mode: .hold))
        XCTAssertTrue(gate.accepts(token))
        XCTAssertEqual(gate.mode, .toggle)
    }

    func testReleaseBeforePermissionCompletesRejectsLateStart() throws {
        var gate = SpeechInputSessionGate()
        let heldToken = try XCTUnwrap(gate.begin(mode: .hold))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(heldToken))
        XCTAssertNil(gate.mode)
        XCTAssertNil(gate.token)
    }

    func testOldRecognitionAndTimeoutCannotFinishANewerUtterance() throws {
        var gate = SpeechInputSessionGate()
        let old = try XCTUnwrap(gate.begin(mode: .hold))
        gate.invalidate()
        let current = try XCTUnwrap(gate.begin(mode: .toggle))
        XCTAssertFalse(gate.accepts(old))
        XCTAssertTrue(gate.accepts(current))
    }

    func testCompletionInvalidationMakesDeliveryAtMostOnce() throws {
        var gate = SpeechInputSessionGate()
        let token = try XCTUnwrap(gate.begin(mode: .toggle))
        XCTAssertTrue(gate.accepts(token))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(token))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(token))
    }
}

@MainActor
final class SpeechInputControllerStartupTests: XCTestCase {
    func testRecordingTriggerAuthorizesThenPreparesDeviceBeforeStartingAudio() async throws {
        for hold in [false, true] {
            let fixture = SpeechStartupFixture()
            fixture.suspendsAuthorization = true; fixture.suspendsPreparation = true
            let controller = fixture.controller()
            defer { controller.cancel(); fixture.resumeAuthorization(); fixture.resumePreparation() }
            XCTAssertTrue(fixture.events.isEmpty, "Creating the voice UI must not request permissions or release device control.")
            if hold { controller.beginHold(beforeRecording: { try await fixture.prepare() }, onTranscript: { _ in }) }
            else { controller.toggle(beforeRecording: { try await fixture.prepare() }, onTranscript: { _ in }) }
            try await waitUntil { fixture.pendingAuthorization != nil }
            XCTAssertEqual(controller.state, .requestingPermission)
            XCTAssertEqual(fixture.events, ["authorize"])
            fixture.resumeAuthorization()
            try await waitUntil { fixture.pendingPreparation != nil }
            XCTAssertEqual(controller.state, .preparing)
            XCTAssertEqual(fixture.events, ["authorize", "authorized", "prepare"])
            fixture.resumePreparation()
            try await waitUntil { controller.isRecording }
            XCTAssertEqual(fixture.events, ["authorize", "authorized", "prepare", "prepared", "audio"])
        }
    }

    func testDeniedPermissionNeverPreparesDeviceOrStartsAudio() async throws {
        let fixture = SpeechStartupFixture()
        fixture.authorizationFailure = NSError(domain: "SpeechStartupFixture", code: 1)
        let controller = fixture.controller()
        controller.toggle(beforeRecording: { try await fixture.prepare() }, onTranscript: { _ in })
        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(fixture.events, ["authorize"])
        XCTAssertEqual(controller.errorMessage, String(localized: "speech.error.unavailable", table: "Speech"))
    }

    func testCancelAndHoldReleasePreventLateAudioAfterAuthorizationOrDevicePreparation() async throws {
        for duringPreparation in [false, true] {
            for releaseHold in [false, true] {
                let fixture = SpeechStartupFixture()
                fixture.suspendsAuthorization = !duringPreparation; fixture.suspendsPreparation = duringPreparation
                let controller = fixture.controller()
                defer { controller.cancel(); fixture.resumeAuthorization(); fixture.resumePreparation() }
                controller.beginHold(beforeRecording: { try await fixture.prepare() }, onTranscript: { _ in })
                try await waitUntil { duringPreparation ? fixture.pendingPreparation != nil : fixture.pendingAuthorization != nil }
                if releaseHold { controller.endHold() } else { controller.cancel() }
                XCTAssertFalse(controller.isBusy)
                fixture.resumeAuthorization(); fixture.resumePreparation()
                try await waitUntil { fixture.events.contains(duringPreparation ? "prepared" : "authorized") }
                XCTAssertFalse(fixture.events.contains("audio"))
                if !duringPreparation { XCTAssertFalse(fixture.events.contains("prepare")) }
                XCTAssertEqual(controller.state, .idle)
                XCTAssertNil(controller.errorMessage)
            }
        }
    }

    func testOldDevicePreparationCannotStartAudioOrCancelANewerRecording() async throws {
        let fixture = SpeechStartupFixture()
        fixture.suspendsPreparation = true
        let controller = fixture.controller()
        defer { controller.cancel(); fixture.resumePreparation() }
        controller.beginHold(beforeRecording: { try await fixture.prepare() }, onTranscript: { _ in })
        try await waitUntil { fixture.pendingPreparation != nil }
        controller.cancel()
        controller.toggle(onTranscript: { _ in })
        try await waitUntil { controller.isRecording }
        fixture.resumePreparation()
        try await waitUntil { fixture.events.contains("prepared") }
        XCTAssertEqual(fixture.events.filter { $0 == "audio" }.count, 1)
        XCTAssertTrue(controller.isRecording)
        XCTAssertNil(controller.errorMessage)
    }

    func testBackgroundDuringDevicePreparationPreventsAudioAndClearsBusyState() async throws {
        let fixture = SpeechStartupFixture()
        fixture.suspendsPreparation = true
        let controller = fixture.controller()
        defer { controller.cancel(); fixture.resumePreparation() }
        controller.toggle(beforeRecording: { try await fixture.prepare() }, onTranscript: { _ in })
        try await waitUntil { fixture.pendingPreparation != nil }
        fixture.isForeground = false
        fixture.resumePreparation()
        try await waitUntil { !controller.isBusy }
        XCTAssertFalse(fixture.events.contains("audio"))
        XCTAssertNil(controller.errorMessage)
    }

    func testDevicePreparationErrorKeepsItsLocalizedMessageAndCancellationClearsBusyState() async throws {
        for cancelled in [false, true] {
            let fixture = SpeechStartupFixture()
            let controller = fixture.controller()
            controller.toggle(beforeRecording: {
                if cancelled { throw CancellationError() }
                throw DictationDevicePreparationError.releaseUnconfirmed
            }, onTranscript: { _ in })
            try await waitUntil { !controller.isBusy }
            XCTAssertFalse(fixture.events.contains("audio"))
            XCTAssertEqual(controller.errorMessage, cancelled ? nil : String(localized: "speech.deviceReleaseFailed", table: "Speech"))
        }
    }

    func testAudioStartupErrorsKeepTheExistingUnavailablePresentation() async throws {
        let fixture = SpeechStartupFixture()
        fixture.audioFailure = NSError(domain: "SpeechStartupFixture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Synthetic audio details"])
        let controller = fixture.controller()
        controller.toggle(beforeRecording: { try await fixture.prepare() }, onTranscript: { _ in })
        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(fixture.events, ["authorize", "authorized", "prepare", "prepared", "audio"])
        XCTAssertEqual(controller.errorMessage, String(localized: "speech.error.unavailable", table: "Speech"))
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        XCTFail("Synthetic speech startup did not reach the expected state.")
        throw NSError(domain: "SpeechInputControllerStartupTests", code: 1)
    }
}

@MainActor private final class SpeechStartupFixture {
    var events: [String] = []
    var suspendsAuthorization = false
    var suspendsPreparation = false
    var isForeground = true
    var authorizationFailure: (any Error)?
    var audioFailure: (any Error)?
    var pendingAuthorization: CheckedContinuation<Void, Never>?
    var pendingPreparation: CheckedContinuation<Void, Never>?

    func controller() -> SpeechInputController {
        SpeechInputController(dependencies: .init(authorize: { [self] in
            events.append("authorize")
            if suspendsAuthorization { await withCheckedContinuation { pendingAuthorization = $0 } }
            if let authorizationFailure { throw authorizationFailure }
            events.append("authorized")
        }, startRecognition: { [self] _, _ in
            events.append("audio")
            if let audioFailure { throw audioFailure }
        }, isForeground: { [self] in isForeground }))
    }

    func prepare() async throws {
        events.append("prepare")
        if suspendsPreparation { await withCheckedContinuation { pendingPreparation = $0 } }
        events.append("prepared")
    }

    func resumeAuthorization() {
        pendingAuthorization?.resume(); pendingAuthorization = nil
    }

    func resumePreparation() {
        pendingPreparation?.resume(); pendingPreparation = nil
    }
}
