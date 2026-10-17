import EiscueAgentKit
import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class DeviceToolSessionTests: XCTestCase {
    func testRegistrationPreservesRuntimeNamesAndCapabilityGatesForEveryScope() {
        let contract: [(name: String, capability: DeviceCapability, action: Bool)] = [
            ("device_screenshot", .screenshot, false), ("device_list_apps", .listApplications, false),
            ("device_tap", .tap, true), ("device_swipe", .swipe, true), ("device_type_text", .textInput, true),
            ("device_launch_app", .launchApplication, true), ("device_home", .home, true),
            ("device_press_key", .keyboardNavigation, true)
        ]
        let client = DeviceClient(actuator: RecordingDeviceController())
        let allCapabilities = DeviceCapability.allCases
        for mask in 0..<(1 << allCapabilities.count) {
            let capabilities = Set(allCapabilities.enumerated().compactMap { index, capability in
                mask & (1 << index) == 0 ? nil : capability
            })
            for scope in TaskScope.allCases {
                let session = DeviceToolSession(capabilities: capabilities, client: client, scope: scope,
                                                timeoutSeconds: 30, log: { _, _ in }, onUnknown: {})
                let expected = contract.filter {
                    scope != .chat && capabilities.contains($0.capability)
                        && (!$0.action || (scope == .control && capabilities.contains(.screenshot)))
                }
                XCTAssertEqual(session.tools.map(\.name), expected.map(\.name), "scope=\(scope), capabilities=\(capabilities)")
            }
        }
    }

    func testEveryRegisteredActionDecodesArgumentsAndReturnsANewObservation() async throws {
        let samples: [(String, AgentJSONValue, Eiscue.DeviceTaskAction)] = [
            ("device_tap", ["x": 12, "y": 34], .tap(DevicePoint(x: 12, y: 34))),
            ("device_swipe", ["fromX": 10, "fromY": 20, "toX": 30, "toY": 40, "duration": 0.5],
             .swipe(from: DevicePoint(x: 10, y: 20), to: DevicePoint(x: 30, y: 40), duration: 0.5)),
            ("device_type_text", ["text": "A test draft"], .typeText("A test draft")),
            ("device_launch_app", ["bundleId": "org.eiscue.fixture"], .launchApplication("org.eiscue.fixture")),
            ("device_home", [:], .home),
            ("device_press_key", ["key": "escape"], .pressKey(.escape))
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for (name, payload, expectedAction) in samples {
            let controller = RecordingDeviceController()
            let session = controlSession(controller)
            _ = try await tool("device_screenshot", in: session).execute([:])
            let sourceFrame = try await frameID(from: controller)
            var arguments = try XCTUnwrap(payload.objectValue)
            arguments["frameId"] = .string(sourceFrame.uuidString)
            let actionTool = try tool(name, in: session)
            let result = try await actionTool.execute(.object(arguments))
            let recorded = await controller.lastAction()
            XCTAssertEqual(try encoder.encode(XCTUnwrap(recorded)), try encoder.encode(expectedAction), name)
            let outputFrame = try await frameID(from: controller)
            XCTAssertNotEqual(outputFrame, sourceFrame, name)
            XCTAssertTrue(result.text.contains(outputFrame.uuidString), name)
            XCTAssertTrue(result.content.contains { if case .image = $0 { true } else { false } }, name)
            XCTAssertTrue(actionTool.mayHaveSideEffects, name)
            XCTAssertTrue(actionTool.verifiesSideEffects, name)
            XCTAssertFalse(actionTool.isVerification, name)
            XCTAssertEqual(actionTool.executionCost, 2, name)
            let counts = await controller.counts()
            XCTAssertEqual(counts.screenshots, 2, name)
        }
    }

    func testChatExposesNoDeviceAccessAndObservationCannotMutateDevice() async throws {
        let controller = RecordingDeviceController()
        let client = DeviceClient(actuator: controller)
        let chat = DeviceToolSession(client: client, scope: .chat, timeoutSeconds: 30,
                                     log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: {})
        let observation = DeviceToolSession(client: client, scope: .observe, timeoutSeconds: 30,
                                            log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: {})

        XCTAssertTrue(chat.tools.isEmpty)
        XCTAssertTrue(observation.tools.allSatisfy { !$0.mayHaveSideEffects })
        XCTAssertNil(observation.tools.first { $0.name == "device_tap" })
        let screenshot = try tool("device_screenshot", in: observation)
        XCTAssertTrue(screenshot.isVerification)
        XCTAssertFalse(try tool("device_list_apps", in: observation).isVerification)
        let result = try await screenshot.execute([:])

        XCTAssertTrue(result.content.contains { if case .image = $0 { true } else { false } })
        let counts = await controller.counts()
        XCTAssertEqual(counts.screenshots, 1)
        XCTAssertEqual(counts.taps, 0)
    }

    func testTouchRequiresLatestScreenshotAndConsumesItsFrame() async throws {
        let controller = RecordingDeviceController()
        let session = controlSession(controller)
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        XCTAssertEqual(tap.executionCost, 2)
        XCTAssertTrue(tap.verifiesSideEffects)
        XCTAssertFalse(tap.isVerification)

        _ = try await screenshot.execute([:])
        let rejectedFrame = try await frameID(from: controller)
        await assertRejected(tap, arguments: tapArguments(frameID: UUID()))
        await assertRejected(tap, arguments: tapArguments(frameID: rejectedFrame))
        _ = try await screenshot.execute([:])
        let firstFrame = try await frameID(from: controller)
        let result = try await tap.execute(tapArguments(frameID: firstFrame))
        XCTAssertTrue(result.content.contains { if case .image = $0 { true } else { false } })
        await assertRejected(tap, arguments: tapArguments(frameID: firstFrame))
        var counts = await controller.counts()
        XCTAssertEqual(counts.taps, 1, "A screenshot must authorize at most one touch.")

        _ = try await screenshot.execute([:])
        let secondFrame = try await frameID(from: controller)
        XCTAssertNotEqual(firstFrame, secondFrame)
        _ = try await tap.execute(tapArguments(frameID: secondFrame))
        counts = await controller.counts()
        XCTAssertEqual(counts.taps, 2)
    }

    func testMalformedFrameIDsUseTheSamePauseGateAndReleaseTheHold() async throws {
        let controller = RecordingDeviceController()
        var held = false
        let session = DeviceToolSession(client: DeviceClient(actuator: controller), scope: .control, timeoutSeconds: 30,
                                        log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: {}, onObservationWillCapture: { held = true },
                                        onActionFinished: { held = false })
        _ = try await tool("device_screenshot", in: session).execute([:])
        let tap = try tool("device_tap", in: session)
        for index in 1...3 {
            do {
                _ = try await tap.execute(["frameId": "invalid", "x": 10, "y": 20])
                XCTFail("Malformed frame ID must be rejected.")
            } catch {
                if index == 3 {
                    guard case .paused = error as? AgentToolError else { return XCTFail("Expected frame rejection pause.") }
                }
            }
        }
        XCTAssertFalse(held)
        XCTAssertEqual(session.pauseReason, .staleFrames)
        let counts = await controller.counts()
        XCTAssertEqual(counts.taps, 0)
    }

    func testAcknowledgmentPersistenceFailureStopsFurtherActionsAndNotifiesHost() async throws {
        let controller = RecordingDeviceController()
        let stopped = expectation(description: "Host stops after losing the action acknowledgment")
        var logKinds: [String] = []
        let session = DeviceToolSession(client: DeviceClient(actuator: controller), scope: .control, timeoutSeconds: 30,
                                        log: { kind, detail in
                                            await controller.fixtureLog(kind, detail)
                                            logKinds.append(kind)
                                            if kind == "action.acknowledged" { throw TestLogError.unavailable }
                                        }, onUnknown: { stopped.fulfill() })
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        _ = try await screenshot.execute([:])
        let frameID = try await frameID(from: controller)

        do {
            _ = try await tap.execute(tapArguments(frameID: frameID))
            XCTFail("The caller must learn that the durable acknowledgment failed.")
        } catch {
            XCTAssertEqual(error as? AgentToolError, .outcomeUnknown)
        }
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertTrue(session.hasUnknownOutcome)
        await assertRejected(screenshot, arguments: [:])
        await assertRejected(tap, arguments: tapArguments(frameID: frameID))

        let counts = await controller.counts()
        XCTAssertEqual(counts.taps, 1, "The first action reached the device; retrying it could duplicate its effect.")
        XCTAssertEqual(counts.screenshots, 1, "A failed session cannot obtain a new frame to authorize more actions.")
        XCTAssertEqual(logKinds.filter { $0 == "action.acknowledged" }.count, 1)
    }

    func testUnknownDeliveryStillNotifiesHostWhenItsLogCannotBeSaved() async throws {
        let unknown = DeviceControlError.deliveryUnknown("No receipt from the mock transport")
        let controller = RecordingDeviceController(tapFailure: unknown)
        let stopped = expectation(description: "Host stops even if the unknown-delivery log is lost")
        var attemptedUnknownLog = false
        let session = DeviceToolSession(client: DeviceClient(actuator: controller), scope: .control, timeoutSeconds: 30,
                                        log: { kind, detail in
                                            await controller.fixtureLog(kind, detail)
                                            if kind == "action.unknown" {
                                                attemptedUnknownLog = true
                                                throw TestLogError.unavailable
                                            }
                                        }, onUnknown: { stopped.fulfill() })
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        _ = try await screenshot.execute([:])
        let frameID = try await frameID(from: controller)

        do {
            _ = try await tap.execute(tapArguments(frameID: frameID))
            XCTFail("Unknown delivery must remain visible to the caller.")
        } catch {
            XCTAssertEqual(error as? AgentToolError, .outcomeUnknown)
        }
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertTrue(session.hasUnknownOutcome)
        await assertRejected(tap, arguments: tapArguments(frameID: frameID))
        await assertRejected(screenshot, arguments: [:])

        XCTAssertTrue(attemptedUnknownLog)
        let counts = await controller.counts()
        XCTAssertEqual(counts.taps, 1)
        XCTAssertEqual(counts.screenshots, 1)
    }

    func testHIDNavigationExposesOnlyAdvertisedCapabilitiesAndConsumesFrames() async throws {
        let controller = RecordingDeviceController()
        let capabilities: Set<DeviceCapability> = [.screenshot, .tap, .textInput, .home, .keyboardNavigation]
        let session = DeviceToolSession(capabilities: capabilities, client: DeviceClient(actuator: controller), scope: .control,
                                        timeoutSeconds: 30, log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: {})
        XCTAssertNil(session.tools.first { $0.name == "device_launch_app" })
        XCTAssertNil(session.tools.first { $0.name == "device_list_apps" })
        let observe = DeviceToolSession(capabilities: capabilities, client: DeviceClient(actuator: controller), scope: .observe,
                                        timeoutSeconds: 30, log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: {})
        XCTAssertNil(observe.tools.first { $0.name == "device_press_key" })
        let screenshot = try tool("device_screenshot", in: session)
        let press = try tool("device_press_key", in: session)
        _ = try await screenshot.execute([:])
        let frame = try await frameID(from: controller)
        let arguments: AgentJSONValue = ["frameId": .string(frame.uuidString), "key": "search"]
        _ = try await press.execute(arguments)
        await assertRejected(press, arguments: arguments)
        _ = try await screenshot.execute([:])
        let invalidFrame = try await frameID(from: controller)
        await assertRejected(press, arguments: ["frameId": .string(invalidFrame.uuidString), "key": "volumeUp"])
        let counts = await controller.counts()
        XCTAssertEqual(counts.keys, 1)

        _ = try await screenshot.execute([:])
        let beforeHome = try await frameID(from: controller)
        _ = try await tool("device_home", in: session).execute(["frameId": .string(beforeHome.uuidString)])
        await assertRejected(press, arguments: ["frameId": .string(beforeHome.uuidString), "key": "enter"])
    }

    func testAllActionSchemasRequireAFrameAndScreenshotCapability() throws {
        let controller = RecordingDeviceController()
        let session = controlSession(controller)
        for tool in session.tools where tool.mayHaveSideEffects {
            XCTAssertTrue(tool.parameters["required"]?.arrayValue?.contains(.string("frameId")) == true)
            XCTAssertEqual(tool.executionCost, 2)
            XCTAssertTrue(tool.verifiesSideEffects)
        }
        let blind = DeviceToolSession(capabilities: [.tap, .home], client: DeviceClient(actuator: controller),
                                      scope: .control, timeoutSeconds: 30, log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: {})
        XCTAssertTrue(blind.tools.isEmpty)
    }

    func testUnknownNavigationDeliveryStopsTheRunWithoutRetry() async throws {
        let failure = DeviceControlError.deliveryUnknown("No navigation receipt")
        let controller = RecordingDeviceController(keyFailure: failure)
        let stopped = expectation(description: "Navigation uncertainty stops the host")
        let session = DeviceToolSession(client: DeviceClient(actuator: controller), scope: .control, timeoutSeconds: 30,
                                        log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: { stopped.fulfill() })
        let screenshot = try tool("device_screenshot", in: session)
        let press = try tool("device_press_key", in: session)
        _ = try await screenshot.execute([:])
        let frame = try await frameID(from: controller)
        let arguments: AgentJSONValue = ["frameId": .string(frame.uuidString), "key": "search"]
        do {
            _ = try await press.execute(arguments)
            XCTFail("Unknown navigation must remain visible.")
        } catch { XCTAssertEqual(error as? AgentToolError, .outcomeUnknown) }
        await fulfillment(of: [stopped], timeout: 1)
        await assertRejected(press, arguments: arguments)
        await assertRejected(screenshot, arguments: [:])
        let counts = await controller.counts()
        XCTAssertEqual(counts.keys, 1)
        XCTAssertEqual(counts.screenshots, 1)
    }

    func testUnchangedScreenWarnsAndPausesBeforeThirdIdenticalAction() async throws {
        let controller = RecordingDeviceController()
        let session = controlSession(controller)
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        _ = try await screenshot.execute([:])
        for expectedCount in 1...2 {
            let frame = try await frameID(from: controller)
            let verification = try await tap.execute(tapArguments(frameID: frame))
            XCTAssertTrue(verification.text.contains("Screen pixels are unchanged"))
            XCTAssertTrue(verification.text.contains("\(expectedCount) identical submissions"))
        }
        let frame = try await frameID(from: controller)
        do {
            _ = try await tap.execute(tapArguments(frameID: frame))
            XCTFail("A third identical tap must pause before dispatch.")
        } catch {
            guard case .paused = error as? AgentToolError else { return XCTFail("Expected a resumable pause, got \(error)") }
        }
        XCTAssertFalse(session.hasUnknownOutcome)
        await assertRejected(screenshot, arguments: [:])
        let counts = await controller.counts()
        XCTAssertEqual(counts.taps, 2)
        XCTAssertEqual(counts.screenshots, 3)
    }

    func testProgressGuardAllowsChangedActionAndResetsWhenScreenChanges() async throws {
        let controller = RecordingDeviceController()
        let session = controlSession(controller)
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        _ = try await screenshot.execute([:])
        for _ in 0..<2 {
            let frame = try await frameID(from: controller)
            _ = try await tap.execute(tapArguments(frameID: frame))
            _ = try await screenshot.execute([:])
        }
        let differentActionFrame = try await frameID(from: controller)
        _ = try await tap.execute(["frameId": .string(differentActionFrame.uuidString), "x": 100, "y": 200])
        await controller.changeScreen(to: Data([1, 2, 3]))
        let verification = try await screenshot.execute([:])
        XCTAssertFalse(verification.text.contains("Screen pixels are unchanged"))
        let newScreenFrame = try await frameID(from: controller)
        _ = try await tap.execute(tapArguments(frameID: newScreenFrame))
        let counts = await controller.counts()
        XCTAssertEqual(counts.taps, 4)
    }

    func testRepeatedStaleScreensPauseWithoutMarkingUnknownDelivery() async throws {
        let controller = RecordingDeviceController(tapFailure: .staleFrame)
        let session = controlSession(controller)
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        for attempt in 1...3 {
            _ = try await screenshot.execute([:])
            let frame = try await frameID(from: controller)
            do {
                _ = try await tap.execute(tapArguments(frameID: frame))
                XCTFail("The fake controller rejects stale frames.")
            } catch {
                if attempt < 3 { XCTAssertEqual(error as? DeviceControlError, .staleFrame) }
                else {
                    guard case .paused = error as? AgentToolError else { return XCTFail("Expected a pause after repeated stale frames, got \(error)") }
                }
            }
        }
        XCTAssertFalse(session.hasUnknownOutcome)
        await assertRejected(screenshot, arguments: [:])
    }

    func testPresentationHooksHoldBetweenCaptureAndKnownActionOutcome() async throws {
        let controller = RecordingDeviceController()
        var held = false
        var releases = 0
        let session = DeviceToolSession(client: DeviceClient(actuator: controller), scope: .control, timeoutSeconds: 30,
                                        log: { kind, detail in
                                            await controller.fixtureLog(kind, detail)
                                            if kind == "observation.captured" || kind == "action.acknowledged" { XCTAssertTrue(held) }
                                        }, onUnknown: {}, onObservationWillCapture: { held = true },
                                        onActionFinished: { held = false; releases += 1 })
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        _ = try await screenshot.execute([:])
        XCTAssertTrue(held)
        let frame = try await frameID(from: controller)
        let result = try await tap.execute(tapArguments(frameID: frame))
        XCTAssertTrue(held, "The automatically captured frame must remain stable for the next decision.")
        XCTAssertTrue(result.content.contains { if case .image = $0 { true } else { false } })
        _ = try await screenshot.execute([:])
        await assertRejected(tap, arguments: tapArguments(frameID: frame))
        XCTAssertFalse(held, "A known rejection must release transcript progress too.")
        XCTAssertEqual(releases, 2)
    }

    func testFailedScreenshotReleasesPresentationHold() async throws {
        let controller = RecordingDeviceController(screenshotFailure: .notConnected)
        var held = false
        let session = DeviceToolSession(client: DeviceClient(actuator: controller), scope: .control, timeoutSeconds: 30,
                                        log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: {}, onObservationWillCapture: { held = true },
                                        onActionFinished: { held = false })
        let screenshot = try tool("device_screenshot", in: session)
        await assertRejected(screenshot, arguments: [:])
        XCTAssertFalse(held)
        XCTAssertFalse(session.hasUnknownOutcome)
    }

    private func controlSession(_ controller: RecordingDeviceController) -> DeviceToolSession {
        DeviceToolSession(client: DeviceClient(actuator: controller), scope: .control, timeoutSeconds: 30,
                          log: { kind, detail in await controller.fixtureLog(kind, detail) }, onUnknown: {})
    }

    private func tool(_ name: String, in session: DeviceToolSession) throws -> AgentTool {
        try XCTUnwrap(session.tools.first { $0.name == name })
    }

    private func tapArguments(frameID: UUID) -> AgentJSONValue {
        ["frameId": .string(frameID.uuidString), "x": 40, "y": 60]
    }

    private func frameID(from controller: RecordingDeviceController) async throws -> UUID {
        let capturedFrameID = await controller.latestFrameID()
        return try XCTUnwrap(capturedFrameID)
    }

    private func assertRejected(_ tool: AgentTool, arguments: AgentJSONValue,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await tool.execute(arguments)
            XCTFail("An invalid or stopped tool invocation must not reach the device.", file: file, line: line)
        } catch { }
    }
}

private enum TestLogError: Error, Equatable { case unavailable }

/// The mock deliberately does not validate frame IDs: that responsibility is
/// exercised at the App's tool boundary, independently of a real transport.
private actor RecordingDeviceController: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?
    var fixtureGeometry: DeviceFrameGeometry?
    private let tapFailure: DeviceControlError?
    private let keyFailure: DeviceControlError?
    private let screenshotFailure: DeviceControlError?
    private var screenshotCount = 0
    private var tapCount = 0
    private var keyCount = 0
    private var frameID: UUID?
    private var screenshotData = Data([0x89, 0x50, 0x4E, 0x47])
    private var recordedAction: Eiscue.DeviceTaskAction?

    init(tapFailure: DeviceControlError? = nil, keyFailure: DeviceControlError? = nil, screenshotFailure: DeviceControlError? = nil) {
        self.tapFailure = tapFailure; self.keyFailure = keyFailure
        self.screenshotFailure = screenshotFailure
    }

    func status() async -> DeviceStatus { .ready(capabilities: Set(DeviceCapability.allCases)) }

    func captureScreenshot() async throws -> DeviceScreenshot {
        screenshotCount += 1
        if let screenshotFailure { throw screenshotFailure }
        let frame = DeviceScreenshot(width: 390, height: 844, mimeType: "image/png", data: screenshotData)
        frameID = frame.frameID
        return frame
    }

    func tap(at point: DevicePoint, frameID: UUID) async throws {
        tapCount += 1
        if let tapFailure { throw tapFailure }
        recordedAction = .tap(point)
    }

    func latestFrameID() -> UUID? { fixtureObservedFrameID }
    func changeScreen(to data: Data) { screenshotData = data }
    func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws {
        keyCount += 1
        if let keyFailure { throw keyFailure }
        recordedAction = .pressKey(key)
    }
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        recordedAction = .swipe(from: from, to: to, duration: seconds)
    }
    func typeText(_ text: String, frameID: UUID) async throws { recordedAction = .typeText(text) }
    func launchApplication(bundleID: String) async throws { recordedAction = .launchApplication(bundleID) }
    func home() async throws { recordedAction = .home }
    func lastAction() -> Eiscue.DeviceTaskAction? { recordedAction }
    func counts() -> (screenshots: Int, taps: Int, keys: Int) { (screenshotCount, tapCount, keyCount) }
}
