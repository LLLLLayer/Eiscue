import EiscueAgentKit
import EiscueDeviceKit
import Foundation

/// JSON/schema adapter for the Eiscue-owned device decision executor.
@MainActor
final class DeviceToolSession {
    private let capabilities: Set<DeviceCapability>
    private let scope: TaskScope
    private let runner: DeviceTaskRunner

    var hasStartedExecution: Bool { runner.hasStartedExecution }
    var hasUnknownOutcome: Bool { runner.hasUnknownOutcome }
    var phase: DeviceTaskPhase { runner.phase }
    var pauseReason: DeviceTaskPauseReason? { runner.pauseReason }

    init(capabilities: Set<DeviceCapability> = Set(DeviceCapability.allCases), client: DeviceClient, scope: TaskScope,
         timeoutSeconds: Int, maxOperations: Int = 30,
         log: @escaping @MainActor (String, String) async throws -> Void,
         onUnknown: @escaping @MainActor () async -> Void,
         onObservationWillCapture: @escaping @MainActor () async -> Void = {},
         onActionFinished: @escaping @MainActor () async -> Void = {},
         onPhaseChanged: @escaping @MainActor (DeviceTaskPhase) -> Void = { _ in }) {
        self.capabilities = capabilities; self.scope = scope
        runner = DeviceTaskRunner(capabilities: capabilities, client: client, scope: scope,
                                  timeoutSeconds: timeoutSeconds, maxOperations: maxOperations, log: log,
                                  onUnknown: onUnknown, onObservationWillCapture: onObservationWillCapture,
                                  onActionFinished: onActionFinished, onPhaseChanged: onPhaseChanged)
    }

    func stop() { runner.stop() }

    var tools: [AgentTool] {
        guard scope != .chat else { return [] }
        var result = [
            tool("device_screenshot", "Observe a fresh screen. Returns an image and frameId with pixel dimensions. Use this frameId for the next action. Each action also returns a fresh screenshot.", properties: [:], required: [], sideEffect: false),
            tool("device_list_apps", "List installed applications and their exact bundle IDs.", properties: [:], required: [], sideEffect: false)
        ]
        if scope == .control {
            let frame: AgentJSONValue = ["type": "string", "description": "frameId from the most recent screenshot"]
            let coordinate: AgentJSONValue = ["type": "number", "minimum": 0]
            result += [
                tool("device_tap", "Tap a pixel coordinate in the newest screenshot. Returns a fresh screenshot and frameId to verify the result and decide the next action.", properties: ["frameId": frame, "x": coordinate, "y": coordinate], required: ["frameId", "x", "y"]),
                tool("device_swipe", "Drag between pixel coordinates. Returns a fresh screenshot and frameId to verify the result and decide the next action.", properties: [
                    "frameId": frame, "fromX": coordinate, "fromY": coordinate, "toX": coordinate, "toY": coordinate,
                    "duration": ["type": "number", "minimum": 0.1, "maximum": 2]
                ], required: ["frameId", "fromX", "fromY", "toX", "toY", "duration"]),
                tool("device_type_text", "Enter text into the focused field visible in the latest screenshot. Replaces the system clipboard and pastes it. Returns a fresh screenshot and frameId to verify the result and decide the next action.", properties: [
                    "frameId": frame, "text": ["type": "string", "maxLength": 4096]
                ], required: ["frameId", "text"]),
                tool("device_launch_app", "Launch an application by exact bundle ID from device_list_apps. Returns a fresh screenshot and frameId to verify the result.", properties: [
                    "frameId": frame, "bundleId": ["type": "string", "minLength": 1, "maxLength": 255]
                ], required: ["frameId", "bundleId"]),
                tool("device_home", "Return to the device home screen. Returns a fresh screenshot and frameId to verify the result and decide the next action.", properties: ["frameId": frame], required: ["frameId"])
            ]
            result.append(tool("device_press_key", "Send one supported keyboard action. search requests system search (Command-Space), enter confirms the visible focused item, escape dismisses the visible panel. Returns a fresh screenshot and frameId after the action; inspect it because a receipt does not prove a shortcut took effect. Only type an app's display name after a fresh screenshot confirms the search field. If a shortcut had no visible effect, navigate using visible controls, such as the AssistiveTouch menu and its Home button, instead of repeating it. Only use tools actually provided. This cannot launch by bundle ID.", properties: [
                "frameId": frame,
                "key": ["type": "string", "enum": .array(DeviceKeyboardAction.allCases.map { .string($0.rawValue) })]
            ], required: ["frameId", "key"]))
        }
        let requirements: [String: DeviceCapability] = [
            "device_screenshot": .screenshot, "device_list_apps": .listApplications,
            "device_tap": .tap, "device_swipe": .swipe, "device_type_text": .textInput,
            "device_launch_app": .launchApplication, "device_home": .home,
            "device_press_key": .keyboardNavigation
        ]
        return result.filter {
            (!$0.mayHaveSideEffects || capabilities.contains(.screenshot))
                && (requirements[$0.name].map { capabilities.contains($0) } ?? false)
        }
    }

    private func tool(_ name: String, _ description: String, properties: [String: AgentJSONValue], required: [String], sideEffect: Bool = true) -> AgentTool {
        AgentTool(name: name, description: description, parameters: [
            "type": "object", "properties": .object(properties),
            "required": .array(required.map { .string($0) }), "additionalProperties": false
        ], mayHaveSideEffects: sideEffect, isVerification: name == "device_screenshot",
           executionCost: sideEffect ? 2 : 1, verifiesSideEffects: sideEffect) { [weak self] arguments in
            guard let self else { throw DeviceTaskError.stopped }
            return try await self.execute(name, arguments: arguments)
        }
    }

    private func execute(_ name: String, arguments: AgentJSONValue) async throws -> AgentToolResult {
        do {
            let next: DeviceDecision
            do { next = try decision(name, arguments: arguments) }
            catch let error as DeviceTaskError { try await runner.rejectInvalidDecision(error) }
            let result = try await runner.step(next)
            switch result {
            case .observation(let observation): return imageResult(observation)
            case .action(let observation):
                return imageResult(observation, prefix: "Action submitted. Inspect the attached fresh screen to verify the result; submission alone is not proof of success. ")
            case .applications(let apps):
                return .text(apps.map { "\($0.name): \($0.bundleID)" }.joined(separator: "\n"))
            }
        } catch DeviceTaskError.budget {
            throw AgentError.toolLimitReached
        } catch DeviceTaskError.paused(let reason) {
            throw AgentError.toolExecutionPaused(reason)
        }
    }

    private func decision(_ name: String, arguments: AgentJSONValue) throws -> DeviceDecision {
        switch name {
        case "device_screenshot": return .observe
        case "device_list_apps": return .listApplications
        default: break
        }
        guard let raw = arguments["frameId"]?.stringValue, let id = UUID(uuidString: raw) else { throw DeviceTaskError.frame }
        let action: DeviceAction
        switch name {
        case "device_tap": action = .tap(try point("x", "y", arguments))
        case "device_swipe":
            action = .swipe(from: try point("fromX", "fromY", arguments), to: try point("toX", "toY", arguments),
                            duration: try number("duration", arguments))
        case "device_type_text":
            guard let text = arguments["text"]?.stringValue else { throw DeviceTaskError.arguments }
            action = .typeText(text)
        case "device_launch_app":
            guard let bundle = arguments["bundleId"]?.stringValue else { throw DeviceTaskError.arguments }
            action = .launchApplication(bundle)
        case "device_home": action = .home
        case "device_press_key":
            guard let raw = arguments["key"]?.stringValue, let key = DeviceKeyboardAction(rawValue: raw) else { throw DeviceTaskError.arguments }
            action = .pressKey(key)
        default: throw DeviceTaskError.scope
        }
        return .action(action, frameID: id)
    }

    private func imageResult(_ observation: DeviceObservation, prefix: String = "") -> AgentToolResult {
        let image = observation.screenshot
        return .image(image.data, mimeType: image.mimeType,
                      caption: "\(prefix)frameId=\(image.frameID.uuidString); width=\(image.width); height=\(image.height); capturedAt=\(image.capturedAt.ISO8601Format()). Coordinates are image pixels. Use this frame for one next action; no additional screenshot is needed unless the screen may have changed.\(observation.feedback)")
    }

    private func point(_ x: String, _ y: String, _ arguments: AgentJSONValue) throws -> DevicePoint {
        DevicePoint(x: try number(x, arguments), y: try number(y, arguments))
    }

    private func number(_ key: String, _ value: AgentJSONValue) throws -> Double {
        guard let number = value[key]?.doubleValue, number.isFinite else { throw DeviceTaskError.arguments }
        return number
    }
}
