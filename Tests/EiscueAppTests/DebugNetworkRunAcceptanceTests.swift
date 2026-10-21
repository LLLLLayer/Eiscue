#if DEBUG
import EiscueAgentKit
import EiscueDeviceCore
import UIKit
import XCTest
@testable import Eiscue

@MainActor
final class DebugNetworkRunAcceptanceTests: XCTestCase {
    func testRecoveryLossAndSettlementReadObservedCountBeforeMutatingObservableValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = DebugNetworkRunAcceptance.Report(directory: directory, reportDestination: directory.appendingPathComponent("report.json"))
        report.value.recovery = .init(processID: 1)
        report.value.observedToolCalls = 2
        report.recordRecoveryLoss(duringOwnedRun: true, uptime: 10)
        XCTAssertEqual(report.value.recovery?.toolsAtLoss, 2)
        XCTAssertEqual(report.value.recovery?.lossObserved, true)
        XCTAssertEqual(report.value.recovery?.lossDuringOwnedRun, true)
        XCTAssertEqual(report.value.recovery?.lossObservedUptime, 10)
        XCTAssertEqual(report.hostInvocations.snapshot().lossUptime, 10)
        report.value.observedToolCalls = 3
        report.recordRecoverySettlement()
        XCTAssertEqual(report.value.recovery?.toolsAfterSettlement, 3)
        XCTAssertEqual(report.value.recovery?.toolsAtLoss, 2)
        report.save()
        let data = try Data(contentsOf: directory.appendingPathComponent("report.json"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recovery = try XCTUnwrap(metadata["recovery"] as? [String: Any])
        XCTAssertEqual(recovery["toolsAtLoss"] as? Int, 2)
        XCTAssertEqual(recovery["toolsAfterSettlement"] as? Int, 3)
    }

    func testVPNRecoveryRejectsUnrelatedRoutesAndContinuationFlags() throws {
        for kind in ["idleVPNRecovery", "externalVPNLoss"] {
            for backend in ["coreDevice", "xcTest"] {
                let base = ["--network-run-backend", backend, "--network-run-case", kind]
                let plan = try DebugNetworkRunAcceptance.Plan(arguments: base)
                XCTAssertTrue(plan.verifiesVPNRecovery)
                XCTAssertTrue(plan.usesAcceptanceTarget)
                XCTAssertFalse(plan.allowsExplicitContinuation)
                XCTAssertFalse(plan.injectsStaleStop)
                XCTAssertEqual(plan.requiredTools, kind == "externalVPNLoss" ? [.screenshot, .home] : [])
                for extra in [["--network-run-route", "usbBoard"], ["--network-run-route", "bluetoothBoard"],
                              ["--network-run-inject-stale-stop"], ["--network-run-allow-explicit-continuation"],
                              ["--network-run-cancel-after-seconds", "1"]] {
                    XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: base + extra))
                }
            }
        }
    }

    func testStaleStopInjectionRequiresExplicitLocalVPNContinuation() throws {
        let base = ["--network-run-backend", "xcTest", "--network-run-case", "inflightStop"]
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: base + ["--network-run-inject-stale-stop"]))
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: base + ["--network-run-allow-explicit-continuation", "--network-run-inject-stale-stop"])
        XCTAssertTrue(plan.injectsStaleStop)
        XCTAssertTrue(plan.allowsExplicitContinuation)
    }

    func testHostInvocationTraceRetainsPostEventTotalsAfterTruncation() {
        let recorder = NetworkAcceptanceHostExecutionRecorder()
        recorder.record(.screenshot, uptime: 1)
        recorder.recordExpiration(uptime: 2)
        recorder.record(.home, uptime: 3)
        recorder.recordObservedVPNLoss(uptime: 4)
        for time in 5...140 { recorder.record(.screenshot, uptime: Double(time)) }
        recorder.recordExpiration(uptime: 150)
        recorder.recordObservedVPNLoss(uptime: 151)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.total, 138)
        XCTAssertEqual(snapshot.expirationUptime, 2)
        XCTAssertEqual(snapshot.lossUptime, 4)
        XCTAssertEqual(snapshot.hostExecuteCallsAfterExpiration, 137)
        XCTAssertEqual(snapshot.hostExecuteCallsAfterObservedVPNLoss, 136)
        XCTAssertEqual(snapshot.invocations.count, 128)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(Set(snapshot.invocations.map(\.tool)), [DeviceToolSpec.screenshot.rawValue, DeviceToolSpec.home.rawValue])
    }

    func testThrowingExecutorStillCountsOneHostEntryAndNoSuccessfulTool() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = DebugNetworkRunAcceptance.Report(directory: directory, reportDestination: directory.appendingPathComponent("report.json"))
        let store = NetworkAcceptanceScriptStore(directory: directory.appendingPathComponent("Admission"))
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest"])
        let tools = [
            AgentTool(name: DeviceToolSpec.screenshot.rawValue, description: "", parameters: [:], mayHaveSideEffects: false) { _ in
                throw AgentToolError.outcomeUnknown
            },
            AgentTool(name: DeviceToolSpec.home.rawValue, description: "", parameters: [:]) { _ in
                XCTFail("No further executor may run after the failed observation.")
                throw AgentToolError.outcomeUnknown
            }
        ]
        let engine = NetworkAcceptanceScriptEngine(plan: plan, tools: tools, store: store, report: report)
        let request = AgentRequest(conversationID: UUID(), prompt: DebugNetworkRunAcceptance.prompt)
        do {
            for try await _ in try await engine.run(request: request) {}
            XCTFail("The failed executor must remain a failed diagnostic.")
        } catch { XCTAssertEqual(error as? AgentToolError, .outcomeUnknown) }
        try await engine.cancel()
        XCTAssertEqual(report.value.observedToolCalls, 0)
        XCTAssertEqual(report.value.hostExecuteCalls, 1)
        XCTAssertEqual(report.value.hostExecutionInvocations.map(\.tool), [DeviceToolSpec.screenshot.rawValue])
        XCTAssertEqual(report.value.hostExecuteCallsAfterExpiration, 0)
        XCTAssertEqual(report.value.hostExecuteCallsAfterObservedVPNLoss, 0)
        let unowned = await store.isUnowned
        XCTAssertTrue(unowned)
    }

    func testLateNotificationSnapshotsAreBoundedAndDiscardOtherIdentifiers() throws {
        let id = UUID(), other = UUID()
        let expected = DebugNetworkRunAcceptance.NotificationEvidence.identifier(for: id)
        var evidence = DebugNetworkRunAcceptance.NotificationEvidence(runID: id, identifier: expected)
        evidence.recordSnapshot(pending: ["private-unrelated"], delivered: [], uptime: 0)
        evidence.recordSnapshot(pending: [expected], delivered: [], uptime: 1)
        evidence.recordSnapshot(pending: [], delivered: [expected, expected,
            DebugNetworkRunAcceptance.NotificationEvidence.identifier(for: other)], uptime: 3)
        evidence.recordSnapshot(pending: [], delivered: [expected], uptime: 5)
        evidence.recordSnapshot(pending: ["private-late"], delivered: [], uptime: 6)
        XCTAssertEqual(evidence.deliverySnapshots.map(\.uptime), [0, 1, 3, 5])
        XCTAssertEqual(evidence.deliverySnapshots.map(\.pendingCount), [0, 1, 0, 0])
        XCTAssertEqual(evidence.deliverySnapshots.map(\.deliveredCount), [0, 0, 1, 1])
        XCTAssertEqual(evidence.deliveredIdentifiers, [expected])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("private"))
    }

    func testExplicitContinuationIsOptInAndLimitedToLocalVPNInflightStop() throws {
        let base = ["--network-run-backend", "xcTest", "--network-run-case", "inflightStop"]
        XCTAssertFalse(try DebugNetworkRunAcceptance.Plan(arguments: base).allowsExplicitContinuation)
        let flag = "--network-run-allow-explicit-continuation"
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: base + [flag])
        XCTAssertTrue(plan.allowsExplicitContinuation)
        XCTAssertEqual(plan.continuationWaitSeconds, 300)
        for arguments in [
            ["--network-run-backend", "xcTest", flag],
            ["--network-run-backend", "coreDevice", "--network-run-case", "foregroundSwipe", flag],
            ["--network-run-backend", "xcTest", "--network-run-route", "usbBoard", "--network-run-case", "inflightStop", flag],
            bluetoothArguments(kind: "inflightStop") + [flag]
        ] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: arguments))
        }
    }

    func testContinuationAdmissionRequiresSettledOriginalAndExactScopeThenCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NetworkAcceptanceScriptStore(directory: directory)
        let conversationID = UUID()
        let original = AgentMessage(role: .user, text: DebugNetworkRunAcceptance.prompt)
        let first = AgentRequest(conversationID: conversationID, requestID: original.id, prompt: original.text)
        _ = try await store.admitScript(first, allowsContinuation: true)
        do {
            try await store.armContinuation(conversationID: conversationID, originalRequestID: original.id, history: [original], prompt: "continue")
            XCTFail("An owned or pending original cannot grant continuation.")
        } catch { XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .unexpectedRequest) }
        try await store.settle(conversationID)
        try await store.armContinuation(conversationID: conversationID, originalRequestID: original.id, history: [original], prompt: "continue")
        let invalid = [
            first,
            AgentRequest(conversationID: UUID(), prompt: "continue", history: [original]),
            AgentRequest(conversationID: conversationID, prompt: "arbitrary task", history: [original]),
            AgentRequest(conversationID: conversationID, prompt: "continue"),
            AgentRequest(conversationID: conversationID, prompt: "continue", mode: .resume, history: [original])
        ]
        for request in invalid {
            do {
                _ = try await store.admitScript(request, allowsContinuation: true)
                XCTFail("Only the explicit original-conversation continuation is eligible.")
            } catch { XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .unexpectedRequest) }
        }
        let valid = AgentRequest(conversationID: conversationID, prompt: "continue", history: [original])
        do {
            _ = try await store.admitScript(valid, allowsContinuation: false)
            XCTFail("The default diagnostic never enables continuation.")
        } catch { XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .unexpectedRequest) }
        let before = try await store.recovery(conversationID)
        XCTAssertEqual(before.acceptedRequestIDs, [original.id])
        XCTAssertFalse(before.hasInterruptedRun)
        await store.closeContinuation()
        do {
            _ = try await store.admitScript(valid, allowsContinuation: true)
            XCTFail("An expired/abandoned window cannot be reopened.")
        } catch { XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .unexpectedRequest) }
        let after = try await store.recovery(conversationID)
        XCTAssertEqual(after.acceptedRequestIDs, [original.id])
    }

    func testExplicitContinuationObservesOnceWithoutReplayingUnknownInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NetworkAcceptanceScriptStore(directory: directory.appendingPathComponent("Admission"))
        let report = DebugNetworkRunAcceptance.Report(directory: directory, reportDestination: directory.appendingPathComponent("report.json"))
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest",
            "--network-run-case", "inflightStop", "--network-run-allow-explicit-continuation"])
        let conversationID = UUID(), oldRunID = UUID(), oldFrame = UUID(), newFrame = UUID()
        let original = AgentMessage(role: .user, text: DebugNetworkRunAcceptance.prompt)
        _ = try await store.admitScript(.init(conversationID: conversationID, requestID: original.id, prompt: original.text), allowsContinuation: true)
        let uncertain = AgentToolCompletion(call: .init(id: "original-swipe", name: DeviceToolSpec.swipe.rawValue, arguments: [:]),
                                            result: .init(content: [], outcome: .unknown))
        await store.record(uncertain, requestID: original.id)
        try await store.settle(conversationID)
        let prompt = String(localized: "run.resume_prompt", table: "Runtime", bundle: Bundle(for: AppModel.self))
        try await store.armContinuation(conversationID: conversationID, originalRequestID: original.id, history: [original], prompt: prompt)
        report.value.initialFrameID = oldFrame
        report.value.continuation = .init(originalRunID: oldRunID, originalRequestID: original.id, conversationID: conversationID,
            originalState: RunState.outcomeUnknown.rawValue, originalStopCause: .outcomeUnknown(toolName: DeviceToolSpec.swipe.rawValue),
            originalEngineClosed: true, originalOwnerReleased: true, readyBeforeReconnect: false)
        let counter = NetworkAcceptanceToolCounter()
        let screenshot = result(frameID: newFrame, image: Data([1, 2, 3]))
        let tools = [
            AgentTool(name: DeviceToolSpec.screenshot.rawValue, description: "", parameters: [:], mayHaveSideEffects: false,
                isVerification: true) { _ in await counter.called(.screenshot); return screenshot },
            AgentTool(name: DeviceToolSpec.swipe.rawValue, description: "", parameters: [:]) { _ in
                await counter.called(.swipe)
                throw AgentToolError.outcomeUnknown
            }
        ]
        let engine = NetworkAcceptanceScriptEngine(plan: plan, tools: tools, store: store, report: report)
        let request = AgentRequest(conversationID: conversationID, prompt: prompt, history: [original])
        var started: [String] = []
        for try await event in try await engine.run(request: request) {
            if case .toolStarted(let call) = event { started.append(call.name) }
        }
        try await engine.cancel()
        XCTAssertEqual(started, [DeviceToolSpec.screenshot.rawValue])
        XCTAssertEqual(report.value.continuation?.frameID, newFrame)
        XCTAssertEqual(report.value.continuation?.toolCalls, 1)
        XCTAssertEqual(report.value.continuation?.imageBytes, 3)
        // A retry acknowledges the same durable request without a second tool.
        for try await _ in try await engine.run(request: request) {}
        let calls = await counter.calls
        XCTAssertEqual(calls, [.screenshot])
        let savedUnknown = await store.result(requestID: original.id, toolCallID: uncertain.call.id)
        XCTAssertEqual(savedUnknown?.result.outcome, .unknown)
        let recovery = try await engine.recover(conversationID: conversationID)
        XCTAssertEqual(recovery.acceptedRequestIDs, [original.id, request.requestID])
        XCTAssertFalse(recovery.hasInterruptedRun)
        let unowned = await store.isUnowned
        XCTAssertTrue(unowned)
        do {
            _ = try await engine.run(request: .init(conversationID: conversationID, prompt: prompt, history: [original]))
            XCTFail("Only one new request can consume the continuation permit.")
        } catch { XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .unexpectedRequest) }
    }

    func testNotificationEvidenceFiltersExactOwnIdentifierAndProtectionStaysOptional() throws {
        let runID = UUID(), other = UUID()
        let expected = DebugNetworkRunAcceptance.NotificationEvidence.identifier(for: runID)
        let identifiers = [expected, expected, expected + ".other",
                           DebugNetworkRunAcceptance.NotificationEvidence.identifier(for: other), "private-unrelated"]
        XCTAssertEqual(DebugNetworkRunAcceptance.NotificationEvidence.matching(identifiers, runID: runID), [expected])
        var sample = DebugNetworkRunAcceptance.Sample(time: Date(), duration: 1, background: true, uptime: 1, gapSeconds: 1, isExecuting: true)
        let unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertNil(unknown["protectedDataAvailable"])
        sample.protectedDataAvailable = false
        let locked = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertEqual(locked["protectedDataAvailable"] as? Bool, false)
    }

    func testAutomationHandoffExposesOnlyFixedSessionMetadata() throws {
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        metadata.phase = "awaiting_external_background"
        metadata.route = "bluetoothBoard"; metadata.inputRoute = "bluetooth"; metadata.acceptanceCase = "hidBackground"
        metadata.registeredToolNames = ["private-untrusted-value"]
        metadata.observationFailures = ["private-error-details"]
        let snapshot = DebugNetworkRunAcceptance.AutomationStatus(metadata, selectedInputRoute: "bluetooth", needsCalibration: false)
        let data = Data(snapshot.encoded.utf8)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["sessionID", "phase", "state", "route", "inputRoute", "acceptanceCase", "selectedInputRoute", "needsCalibration", "recoveryLossObserved", "recoveryReady", "staleStopRequired"])
        XCTAssertFalse(snapshot.encoded.contains("private"))
        XCTAssertEqual(try JSONDecoder().decode(DebugNetworkRunAcceptance.AutomationStatus.self, from: data), snapshot)
    }

    func testBackgroundProgressKeepsOriginalAndRecentEvidenceWithoutCountingIdlePolls() {
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        func sample(_ count: Int64, time: Double, accepted: Bool = true, appState: Int = 0) -> DebugNetworkRunAcceptance.BackgroundProgress {
            .init(uptime: time, completed: count, total: 1_000_000, accepted: accepted,
                  applicationState: appState, lowPowerMode: false, thermalState: 0)
        }
        metadata.recordBackgroundProgress(sample(0, time: 0))
        metadata.recordBackgroundProgress(sample(0, time: 10))
        XCTAssertEqual(metadata.backgroundProgress.count, 1, "Waiting alone does not produce progress evidence.")
        metadata.recordBackgroundProgress(sample(0, time: 11, appState: 2))
        metadata.recordBackgroundProgress(sample(0, time: 12, accepted: false, appState: 2))
        XCTAssertEqual(metadata.backgroundProgress.count, 3, "Background transitions and refused updates remain visible.")
        for count in 1...100 { metadata.recordBackgroundProgress(sample(Int64(count), time: Double(count + 12))) }
        XCTAssertEqual(metadata.backgroundProgress.count, 64)
        XCTAssertEqual(metadata.backgroundProgress.first?.uptime, 0)
        XCTAssertEqual(metadata.backgroundProgress.last?.completed, 100)
    }

    func testExistingNetworkDefaultsStillRequireAnExplicitBackend() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest"])
        XCTAssertEqual(plan.route, .localVPN)
        XCTAssertEqual(plan.backend, .xcTest)
        XCTAssertEqual(plan.kind, .background)
        XCTAssertTrue(plan.requiresLocalTunnel)
        XCTAssertFalse(plan.usesInputTarget)
        XCTAssertFalse(plan.usesAcceptanceTarget)
        let resume = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--resume-existing-local-tunnel"])
        XCTAssertTrue(resume.requiresLocalTunnel)
        XCTAssertTrue(resume.resumeTunnel)
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: []))
    }

    func testBluetoothForegroundSwipeHasNoNetworkBackendOrTunnel() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments())
        XCTAssertEqual(plan.route, .bluetoothBoard)
        XCTAssertNil(plan.backend)
        XCTAssertEqual(plan.kind, .foregroundSwipe)
        XCTAssertTrue(plan.usesInputTarget)
        XCTAssertTrue(plan.usesAcceptanceTarget)
        XCTAssertFalse(plan.resumeTunnel)
        XCTAssertFalse(plan.requiresLocalTunnel)
        XCTAssertFalse(plan.contactComparison)
        XCTAssertEqual(plan.maxToolCalls, 3)
    }

    func testBluetoothAllowsOwnedInputAndExplicitHIDBackgroundCases() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "inflightStop"))
        XCTAssertTrue(plan.usesInputTarget)
        for kind in ["background", "appReturn", "unknown"] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: kind)))
        }
    }

    func testHIDBackgroundUsesOnlyObservationAndWaitsForAnExternalTransition() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "hidBackground"))
        XCTAssertEqual(plan.route, .bluetoothBoard)
        XCTAssertNil(plan.backend)
        XCTAssertEqual(plan.inputRoute, .bluetooth)
        XCTAssertEqual(plan.requiredTools, [.screenshot])
        XCTAssertFalse(plan.usesInputTarget)
        XCTAssertTrue(plan.usesAcceptanceTarget, "HID background shows real setup then the owned page without requiring an input trace.")
        XCTAssertTrue(plan.samplesBackground)
        XCTAssertEqual(plan.backgroundWaitSeconds, 60)
        XCTAssertEqual(plan.seconds, 60)
        XCTAssertEqual(plan.interval, 15)
        XCTAssertEqual(plan.sampleGapLimit, 20)
        let session = DeviceToolSession(capabilities: [.screenshot],
            client: DeviceClient(actuator: RestrictedBLEAcceptanceActuator()), scope: .control,
            timeoutSeconds: 10, log: { _, _ in }, onUnknown: {})
        XCTAssertNil(plan.firstMissingTool(in: session.tools), "A HID background check must not need Home, launch or swipe.")
    }

    func testNCMOwnedInputCasesUseExplicitBackendAndNoTunnelOrHIDSetup() throws {
        for backend in ["coreDevice", "xcTest"] {
            for kind in ["foregroundSwipe", "inflightStop"] {
                let plan = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-route", "usbBoard",
                    "--network-run-backend", backend, "--network-run-case", kind])
                XCTAssertEqual(plan.route, .usbBoard)
                XCTAssertEqual(plan.backend?.rawValue, backend)
                XCTAssertNil(plan.inputRoute)
                XCTAssertFalse(plan.requiresLocalTunnel)
                XCTAssertFalse(plan.resumeTunnel)
                XCTAssertFalse(plan.contactComparison)
                XCTAssertTrue(plan.usesInputTarget)
                XCTAssertTrue(plan.usesAcceptanceTarget)
                XCTAssertEqual(plan.requiredTools, [.screenshot, .swipe])
                XCTAssertEqual(plan.maxToolCalls, kind == "foregroundSwipe" ? 3 : 70)
                XCTAssertNoThrow(try plan.validateBluetoothSetup(.ready(capabilities: [.screenshot, .swipe])))
                XCTAssertFalse(DeviceRunCleanup.acceptsRelease(confirmed: false, method: plan.route))
                XCTAssertTrue(DeviceRunCleanup.acceptsRelease(confirmed: true, method: plan.route))
            }
        }
    }

    func testNCMRejectsImplicitBackendTunnelResumeAndHIDArguments() {
        let base = ["--network-run-route", "usbBoard", "--network-run-case", "foregroundSwipe"]
        for backend in [[], ["--network-run-backend"], ["--network-run-backend", "automatic"], ["--network-run-backend", "unknown"]] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: base + backend))
        }
        let explicit = base + ["--network-run-backend", "xcTest"]
        for extra in [["--resume-existing-local-tunnel"], ["--network-run-input-route", "usb"],
                      ["--network-run-input-route", "bluetooth"], ["--network-run-contact-comparison"]] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: explicit + extra))
        }
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-route", "usbBoard",
            "--network-run-backend", "coreDevice", "--network-run-case", "hidBackground"]))
    }

    func testHIDInputRouteIsExplicitForAllHIDCasesAndRejectedForNetworkCases() throws {
        for kind in ["hidBackground", "foregroundSwipe", "inflightStop"] {
            for route in ["bluetooth", "usb"] {
                let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: kind) + ["--network-run-input-route", route])
                XCTAssertEqual(plan.inputRoute?.rawValue, route)
            }
        }
        for extra in [["--network-run-input-route"], ["--network-run-input-route", "unknown"],
                      ["--network-run-input-route", "usb", "--network-run-contact-comparison"],
                      ["--network-run-cancel-after-seconds", "1"]] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "hidBackground") + extra))
        }
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--network-run-case", "hidBackground"]))
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--network-run-input-route", "usb"]))
    }

    func testHIDBackgroundRequiresTapTextCalibrationButDoesNotRequireSwipe() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "hidBackground"))
        XCTAssertNoThrow(try plan.validateBluetoothSetup(.ready(capabilities: [.screenshot, .tap, .textInput])))
        for status in [DeviceStatus.unavailable(reason: "fixture"), .ready(capabilities: [.screenshot]), .ready(capabilities: [.screenshot, .tap])] {
            XCTAssertThrowsError(try plan.validateBluetoothSetup(status)) {
                XCTAssertEqual($0 as? DebugNetworkRunAcceptance.Failure, .bluetoothCalibrationRequired)
            }
        }
    }

    func testBackgroundWaitDoesNotAcceptInactiveAndReturnsOnlyAfterBackground() async throws {
        var state = UIApplication.State.active
        var observations: [UIApplication.State] = []
        let transition = Task { @MainActor in
            state = .inactive
            try await Task.sleep(for: .milliseconds(100))
            state = .background
        }
        defer { transition.cancel() }
        try await DebugNetworkRunAcceptance.waitForBackground(timeoutSeconds: 1, applicationState: {
            observations.append(state)
            return state
        })
        XCTAssertTrue(observations.contains(.inactive))
        XCTAssertEqual(observations.last, .background)
    }

    func testBackgroundWaitTimesOutAndHonorsCancellationWithoutFakingBackground() async throws {
        do {
            try await DebugNetworkRunAcceptance.waitForBackground(timeoutSeconds: 0.01, applicationState: { .active })
            XCTFail("A foreground process must not pass the background gate.")
        } catch { XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .didNotBackground) }
        let waiting = Task { @MainActor in
            try await DebugNetworkRunAcceptance.waitForBackground(timeoutSeconds: 1, applicationState: { .inactive })
        }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Cancellation must settle the wait.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testBluetoothSwipePreflightRejectsTapAndTextOnlyBeforeSubmission() throws {
        for kind in ["foregroundSwipe", "inflightStop"] {
            let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: kind))
            XCTAssertThrowsError(try plan.validateBluetoothSetup(.ready(capabilities: [.screenshot, .tap, .textInput]))) {
                XCTAssertEqual($0 as? DebugNetworkRunAcceptance.Failure, .bluetoothSwipeCheckRequired)
            }
            XCTAssertNoThrow(try plan.validateBluetoothSetup(.ready(capabilities: [.screenshot, .tap, .textInput, .swipe])))
        }
        let network = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest"])
        XCTAssertNoThrow(try network.validateBluetoothSetup(.ready(capabilities: [.screenshot, .home])))
    }

    func testRestrictedBLEToolRegistrationSupportsOnlyTheOwnedSwipeCases() throws {
        let session = DeviceToolSession(capabilities: [.screenshot, .swipe],
            client: DeviceClient(actuator: RestrictedBLEAcceptanceActuator()), scope: .control,
            timeoutSeconds: 10, log: { _, _ in }, onUnknown: {})
        let tools = session.tools
        XCTAssertEqual(Set(tools.map(\.name)), Set([DeviceToolSpec.screenshot.rawValue, DeviceToolSpec.swipe.rawValue]))
        for kind in ["foregroundSwipe", "inflightStop"] {
            let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: kind))
            XCTAssertEqual(plan.requiredTools, [.screenshot, .swipe])
            XCTAssertNil(plan.firstMissingTool(in: tools))
        }
        let background = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest"])
        XCTAssertEqual(background.firstMissingTool(in: tools), .home)
        let comparison = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments() + ["--network-run-contact-comparison"])
        XCTAssertNil(comparison.firstMissingTool(in: tools))
        XCTAssertEqual(comparison.requiredTools, [.screenshot, .swipe])
        XCTAssertEqual(comparison.maxToolCalls, DeviceToolSpec.screenshot.executionCost + 2 * DeviceToolSpec.swipe.executionCost)
    }

    func testContactComparisonRequiresExplicitBLEForegroundAndReservesBothActions() throws {
        let flag = "--network-run-contact-comparison"
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments() + [flag])
        XCTAssertTrue(plan.contactComparison)
        XCTAssertEqual(plan.maxToolCalls, 5)
        XCTAssertEqual(plan.expectedSwipeCount, 2)
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "inflightStop") + [flag]))
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", flag]))
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--network-run-case", "foregroundSwipe", flag]))
        let initial = UUID(), stationaryFrame = UUID()
        let next = try DebugNetworkRunAcceptance.postActionFrameID(initialFrameID: initial, result: result(frameID: stationaryFrame, image: Data([1])))
        XCTAssertEqual(next, stationaryFrame, "The moving action must use the stationary action's returned grant.")
    }

    func testEmptyChatRegistrationIdentifiesScreenshotAsTheFirstMissingTool() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments())
        let chat = DeviceToolSession(capabilities: [.screenshot, .swipe],
            client: DeviceClient(actuator: RestrictedBLEAcceptanceActuator()), scope: .chat,
            timeoutSeconds: 10, log: { _, _ in }, onUnknown: {})
        XCTAssertTrue(chat.tools.isEmpty)
        XCTAssertEqual(plan.firstMissingTool(in: chat.tools), .screenshot)
        let observe = DeviceToolSession(capabilities: [.screenshot, .swipe],
            client: DeviceClient(actuator: RestrictedBLEAcceptanceActuator()), scope: .observe,
            timeoutSeconds: 10, log: { _, _ in }, onUnknown: {})
        XCTAssertEqual(plan.firstMissingTool(in: observe.tools), .swipe)
    }

    func testBluetoothRejectsAmbiguousNetworkAndConflictingDiagnosticArguments() {
        for extra in [["--network-run-backend", "coreDevice"], ["--resume-existing-local-tunnel"],
                      ["--network-run-cancel-after-seconds", "1"], ["--ui-testing"], ["--owned-device-check"], ["--ble-device-check"]] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments() + extra), "\(extra)")
        }
        for route in ["unknown"] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-route", route, "--network-run-backend", "xcTest"]))
        }
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--network-run-route"]))
    }

    func testSwipeRequiresTheActionsNewNonemptyImageAndVisibleMovement() throws {
        let initial = UUID(), next = UUID()
        let evidence = try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initial,
            result: result(frameID: next, image: Data([1, 2, 3])), startRowY: 200, endRowY: 150)
        XCTAssertEqual(evidence.initialFrameID, initial)
        XCTAssertEqual(evidence.postActionFrameID, next)
        XCTAssertEqual(evidence.postActionImageBytes, 3)
        XCTAssertEqual(evidence.rowDeltaPoints, 50)
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        try metadata.verifyMovingSwipe(initialFrameID: initial, result: result(frameID: next, image: Data([1, 2, 3])), startRowY: 200, endRowY: 150)
        XCTAssertEqual(metadata.motionVerified, true)
        XCTAssertNil(metadata.motionFailure)
    }

    func testSwipeRejectsOldFramesEmptyImagesAndFailedResults() {
        let initial = UUID()
        for returned in [result(frameID: initial, image: Data([1])), result(frameID: UUID(), image: Data()),
                         result(frameID: UUID(), image: nil), result(frameID: UUID(), image: Data([1]), outcome: .failed)] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initial,
                result: returned, startRowY: 200, endRowY: 150)) { error in
                XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .postActionObservationMissing)
            }
        }
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initial,
            result: .image(Data([1]), mimeType: "image/jpeg"), startRowY: 200, endRowY: 150)) { error in
            XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .invalidFrame)
        }
    }

    func testSwipeRejectsSmallOrNonfiniteUIKitMovement() {
        for end in [200.0, 170, 230, .nan, .infinity] {
            let initial = UUID(), next = UUID()
            let observed = result(frameID: next, image: Data([1, 2, 3]))
            var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
            metadata.recordSwipeReturn(initialFrameID: initial, result: observed, startRowY: 200, endRowY: end)
            XCTAssertEqual(metadata.initialFrameID, initial)
            XCTAssertEqual(metadata.postActionFrameID, next)
            XCTAssertEqual(metadata.postActionImageBytes, 3, "Failed motion must retain the action's actual returned image evidence.")
            XCTAssertEqual(metadata.swipeEndRowYPoints, end.isFinite ? end : nil)
            XCTAssertEqual(metadata.swipeRowDeltaPoints, end.isFinite ? abs(end - 200) : nil)
            XCTAssertNoThrow(try metadata.verifyMovingSwipe(initialFrameID: initial, result: observed, startRowY: 200, endRowY: end),
                "Visual failure must allow normal host completion/retention measurement.")
            XCTAssertEqual(metadata.motionVerified, false)
            XCTAssertEqual(metadata.motionFailure, DebugNetworkRunAcceptance.Failure.swipeDidNotMove.rawValue)
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initial,
                result: observed, startRowY: 200, endRowY: end)) { error in
                XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .swipeDidNotMove)
            }
        }
    }

    func testMetadataPreservesRawHIDReleaseSeparatelyFromLocalPolicyAndRetention() throws {
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        metadata.route = DeviceConnectionMethod.bluetoothBoard.rawValue
        metadata.cleanupConfirmed = false
        metadata.cleanupLocallyAccepted = DeviceRunCleanup.acceptsRelease(confirmed: false, method: .bluetoothBoard)
        metadata.retentionCheckedBeforeTeardown = true
        metadata.hostEngineClosedBeforeTeardown = true
        metadata.hostOwnerReleased = true
        metadata.retainedBluetoothConnected = true
        metadata.retainedScreenSharing = true
        metadata.retainedCalibration = true
        metadata.retainedReady = true
        metadata.scopeBeforeSubmission = TaskScope.control.rawValue
        metadata.runScope = TaskScope.chat.rawValue
        metadata.registeredToolNames = []
        metadata.missingToolName = DeviceToolSpec.screenshot.rawValue
        metadata.touchReceipts = [.init(gesture: .stationary, contactID: 1, type: 0, typeName: DebugNetworkRunAcceptance.touchTypeName(.direct),
                                       phase: "began", uptime: 1, receivedUptime: 1, x: 10, y: 20)]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        XCTAssertEqual(json["cleanupConfirmed"] as? Bool, false)
        XCTAssertEqual(json["cleanupLocallyAccepted"] as? Bool, true)
        XCTAssertEqual(json["retentionCheckedBeforeTeardown"] as? Bool, true)
        XCTAssertEqual(json["retainedCalibration"] as? Bool, true)
        XCTAssertEqual(json["scopeBeforeSubmission"] as? String, TaskScope.control.rawValue)
        XCTAssertEqual(json["runScope"] as? String, TaskScope.chat.rawValue)
        XCTAssertEqual(json["registeredToolNames"] as? [String], [])
        XCTAssertEqual(json["missingToolName"] as? String, DeviceToolSpec.screenshot.rawValue)
        XCTAssertEqual(json["modelRequests"] as? Int, 0)
        XCTAssertEqual(json["realAI"] as? Bool, false)
        XCTAssertEqual(json["realPiRuntime"] as? Bool, false)
        let touches = try XCTUnwrap(json["touchReceipts"] as? [[String: Any]])
        XCTAssertEqual(touches.first?["gesture"] as? String, "stationary")
        XCTAssertEqual(touches.first?["contactID"] as? Int, 1)
        XCTAssertEqual(touches.first?["typeName"] as? String, "direct")
        XCTAssertNil(json["content"])
        XCTAssertNil(json["image"])
        XCTAssertNil(json["credentials"])
    }

    func testReadinessTraceKeepsSetupAndRecentChangesWithoutRepeatingStablePolls() {
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        var state = DebugNetworkRunAcceptance.ReadinessState()
        state.status = "ready"; state.pointerVerified = true
        metadata.recordReadiness(phase: "setup_ready", state: state, uptime: 1)
        metadata.recordReadiness(phase: "stable_poll", state: state, uptime: 2)
        XCTAssertEqual(metadata.readiness.count, 1)
        for index in 0..<40 {
            state.pointerVerified = index.isMultiple(of: 2)
            metadata.recordReadiness(phase: "probe_\(index)", state: state, force: true, uptime: Double(index + 3))
        }
        XCTAssertEqual(metadata.readiness.count, 32)
        XCTAssertEqual(metadata.readiness.first?.phase, "setup_ready")
        XCTAssertEqual(metadata.readiness.last?.phase, "probe_39")
        XCTAssertEqual(metadata.readiness.last?.state.pointerVerified, false)
    }

    func testReadinessReasonsAndPayloadExposeOnlyControlledMetadata() throws {
        XCTAssertEqual(DebugNetworkRunAcceptance.readinessReasonCode(DeviceControlError.staleFrame.localizedDescription), "staleFrame")
        XCTAssertEqual(DebugNetworkRunAcceptance.readinessReasonCode("untrusted private text"), "unclassified")
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        var state = DebugNetworkRunAcceptance.ReadinessState()
        state.statusReasonCode = DebugNetworkRunAcceptance.readinessReasonCode("untrusted private text")
        state.screenSessionChangedFromSetup = true; state.screenGeometryChangedFromSetup = false
        state.operationChangedFromSetup = true; state.owner = "none"
        metadata.recordReadiness(phase: "before_teardown", state: state)
        let encoded = try JSONEncoder().encode(metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let samples = try XCTUnwrap(json["readiness"] as? [[String: Any]])
        let saved = try XCTUnwrap(samples.first?["state"] as? [String: Any])
        XCTAssertEqual(saved["statusReasonCode"] as? String, "unclassified")
        XCTAssertEqual(saved["screenSessionChangedFromSetup"] as? Bool, true)
        XCTAssertNil(saved["screenSessionID"])
        XCTAssertNil(saved["operationID"])
        XCTAssertNil(saved["unavailableReason"])
        XCTAssertNil(saved["image"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("untrusted private text"))
    }

    func testSetupCannotBecomeStableWhileCalibrationModalOrLeaseStillExists() {
        var gate = DebugNetworkRunAcceptance.StabilityGate<Int>()
        // Ready calibration with a presented/dismissing modal remains ineligible.
        XCTAssertFalse(gate.update(eligible: false, value: 1, uptime: 0))
        XCTAssertFalse(gate.update(eligible: false, value: 1, uptime: 10))
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 11))
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 11.9))
        // A recreated setup owner resets the full stability interval.
        XCTAssertFalse(gate.update(eligible: false, value: 1, uptime: 12))
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 12.1))
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 13))
        XCTAssertTrue(gate.update(eligible: true, value: 1, uptime: 13.1))
    }

    func testSetupStabilityResetsOnSessionIdentityChangeAndLostReadiness() {
        var gate = DebugNetworkRunAcceptance.StabilityGate<Int>()
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 0))
        XCTAssertFalse(gate.update(eligible: true, value: 2, uptime: 1))
        XCTAssertFalse(gate.update(eligible: true, value: 2, uptime: 1.9))
        XCTAssertTrue(gate.update(eligible: true, value: 2, uptime: 2))
        XCTAssertFalse(gate.update(eligible: false, value: 2, uptime: 3))
        XCTAssertFalse(gate.update(eligible: true, value: 2, uptime: 4))
        XCTAssertTrue(gate.update(eligible: true, value: 2, uptime: 5))
    }

    private func bluetoothArguments(kind: String = "foregroundSwipe") -> [String] {
        ["--network-run-acceptance", "--network-run-route", "bluetoothBoard", "--network-run-case", kind]
    }
    private func result(frameID: UUID, image: Data?, outcome: AgentToolOutcome = .succeeded) -> AgentToolResult {
        var content: [AgentToolContent] = [.text("frameId=\(frameID.uuidString); width=100; height=200;")]
        if let image { content.append(.image(data: image, mimeType: "image/jpeg")) }
        return AgentToolResult(content: content, outcome: outcome)
    }
}

private actor RestrictedBLEAcceptanceActuator: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?
    var fixtureGeometry: DeviceFrameGeometry?
    func status() async -> DeviceStatus { .ready(capabilities: [.screenshot, .swipe]) }
}
private actor NetworkAcceptanceToolCounter {
    private(set) var calls: [DeviceToolSpec] = []
    func called(_ spec: DeviceToolSpec) { calls.append(spec) }
}
#endif
