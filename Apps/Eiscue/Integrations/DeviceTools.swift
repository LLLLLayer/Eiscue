import EiscueAgentKit
import EiscueDeviceCore
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
        DeviceToolSpec.allCases.filter { $0.isAvailable(scope: scope, capabilities: capabilities) }.map { spec in
            let schema = spec.schema
            return AgentTool(name: spec.rawValue, description: schema.description, parameters: schema.parameters,
                             mayHaveSideEffects: spec.mayHaveSideEffects, isVerification: spec.isVerification,
                             executionCost: spec.executionCost, verifiesSideEffects: spec.verifiesSideEffects, contextImagePolicy: .latest(2)) { [weak self] arguments in
                guard let self else { throw DeviceTaskError.stopped }
                return try await self.execute(spec, arguments: arguments)
            }
        }
    }

    private func execute(_ spec: DeviceToolSpec, arguments: AgentJSONValue) async throws -> AgentToolResult {
        do {
            let next: DeviceDecision
            do { next = try decision(spec, arguments: arguments) }
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
        } catch let error as DeviceControlError where error.isDeliveryUnknown {
            throw AgentToolError.outcomeUnknown
        } catch DeviceTaskError.paused {
            let reason: AgentPauseReason = switch runner.pauseReason {
            case .verificationUnavailable: .verificationUnavailable
            case .connectionLost: .connectionLost
            default: .noProgress
            }
            throw AgentToolError.paused(reason)
        } catch {
            if runner.hasUnknownOutcome { throw AgentToolError.outcomeUnknown }
            throw error
        }
    }

    private func decision(_ spec: DeviceToolSpec, arguments: AgentJSONValue) throws -> DeviceDecision {
        switch spec {
        case .screenshot: return .observe
        case .listApplications: return .listApplications
        case .tap, .swipe, .typeText, .launchApplication, .home, .pressKey: break
        }
        guard let raw = arguments["frameId"]?.stringValue, let id = UUID(uuidString: raw) else { throw DeviceTaskError.frame }
        let action: DeviceTaskAction
        switch spec {
        case .tap: action = .tap(try point("x", "y", arguments))
        case .swipe:
            action = .swipe(from: try point("fromX", "fromY", arguments), to: try point("toX", "toY", arguments),
                            duration: try number("duration", arguments))
        case .typeText:
            guard let text = arguments["text"]?.stringValue else { throw DeviceTaskError.arguments }
            action = .typeText(text)
        case .launchApplication:
            guard let bundle = arguments["bundleId"]?.stringValue else { throw DeviceTaskError.arguments }
            action = .launchApplication(bundle)
        case .home: action = .home
        case .pressKey:
            guard let raw = arguments["key"]?.stringValue, let key = DeviceKeyboardAction(rawValue: raw) else { throw DeviceTaskError.arguments }
            action = .pressKey(key)
        case .screenshot, .listApplications: throw DeviceTaskError.scope
        }
        return .action(action, frameID: id)
    }

    private func imageResult(_ observation: DeviceObservation, prefix: String = "") -> AgentToolResult {
        let image = observation.screenshot
        return .image(image.data, mimeType: image.mimeType,
                      caption: "\(prefix)frameId=\(image.frameID.uuidString); width=\(image.width); height=\(image.height); capturedAt=\(image.capturedAt.ISO8601Format()). Coordinates are pixels in this attached image: top-left=(0,0), bottom-right=(\(image.width - 1),\(image.height - 1)). Do not use screen points, a resized preview's coordinates, or 0-1000 normalization. Use this frame for one next action; no additional screenshot is needed unless the screen may have changed.\(observation.feedback)")
    }

    private func point(_ x: String, _ y: String, _ arguments: AgentJSONValue) throws -> DevicePoint {
        DevicePoint(x: try number(x, arguments), y: try number(y, arguments))
    }

    private func number(_ key: String, _ value: AgentJSONValue) throws -> Double {
        guard let number = value[key]?.doubleValue, number.isFinite else { throw DeviceTaskError.arguments }
        return number
    }
}

// Agent schemas stay in the model adapter; DeviceTaskRunner uses only the
// catalog's DeviceKit metadata and typed decisions.
extension DeviceToolSpec {
    struct Schema {
        let description: String
        let properties: [String: AgentJSONValue]
        let required: [String]

        var parameters: AgentJSONValue {
            ["type": "object", "properties": .object(properties),
             "required": .array(required.map { .string($0) }), "additionalProperties": false]
        }
    }

    var schema: Schema {
        let frame: AgentJSONValue = ["type": "string", "description": "frameId from the most recent screenshot"]
        let coordinate: AgentJSONValue = ["type": "number", "minimum": 0,
                                          "description": "Pixels in the attached screenshot at its declared width and height, not screen points or normalized coordinates."]
        return switch self {
        case .screenshot:
            Schema(description: "Observe a fresh screen. Returns an image and frameId with pixel dimensions. Use this frameId for the next action. Each action also returns a fresh screenshot.", properties: [:], required: [])
        case .listApplications:
            Schema(description: "Optionally list installed applications and their exact bundle IDs when needed for bundle-ID launch. Visible navigation using screenshots and provided Home/tap tools does not require this list. If this query is unavailable, take a new screenshot and use the visible controls; do not repeatedly query the same unavailable service.", properties: [:], required: [])
        case .tap:
            Schema(description: "Tap a pixel coordinate in the newest screenshot. Returns a fresh screenshot and frameId to verify the result and decide the next action.", properties: ["frameId": frame, "x": coordinate, "y": coordinate], required: ["frameId", "x", "y"])
        case .swipe:
            Schema(description: "Drag between pixel coordinates. Returns a fresh screenshot and frameId to verify the result and decide the next action.", properties: [
                    "frameId": frame, "fromX": coordinate, "fromY": coordinate, "toX": coordinate, "toY": coordinate,
                    "duration": ["type": "number", "minimum": .number(DeviceInputValidation.minimumSwipeSeconds), "maximum": .number(DeviceInputValidation.maximumSwipeSeconds)]
                ], required: ["frameId", "fromX", "fromY", "toX", "toY", "duration"])
        case .typeText:
            Schema(description: "Enter text into the focused field visible in the latest screenshot. Replaces the system clipboard and pastes it. Returns a fresh screenshot and frameId to verify the result and decide the next action.", properties: [
                    "frameId": frame, "text": ["type": "string", "maxLength": .number(Double(DeviceInputValidation.maximumTextBytes))]
                ], required: ["frameId", "text"])
        case .launchApplication:
            Schema(description: "Launch an application by exact bundle ID from device_list_apps. Returns a fresh screenshot and frameId to verify the result.", properties: [
                    "frameId": frame, "bundleId": ["type": "string", "minLength": 1, "maxLength": .number(Double(DeviceInputValidation.maximumBundleIDBytes))]
                ], required: ["frameId", "bundleId"])
        case .home:
            Schema(description: "Return to the device home screen. Returns a fresh screenshot and frameId to verify the result and decide the next action.", properties: ["frameId": frame], required: ["frameId"])
        case .pressKey:
            Schema(description: "Send one supported keyboard action. search requests system search (Command-Space), enter confirms the visible focused item, escape dismisses the visible panel. Returns a fresh screenshot and frameId after the action; inspect it because a receipt does not prove a shortcut took effect. Only type an app's display name after a fresh screenshot confirms the search field. If a shortcut had no visible effect, navigate using visible controls, such as the AssistiveTouch menu and its Home button, instead of repeating it. Only use tools actually provided. This cannot launch by bundle ID.", properties: [
                "frameId": frame,
                "key": ["type": "string", "enum": .array(DeviceKeyboardAction.allCases.map { .string($0.rawValue) })]
            ], required: ["frameId", "key"])
        }
    }
}
