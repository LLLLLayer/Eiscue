import EiscueAgentKit
import EiscueDeviceKit
import Foundation

/// All native device tools pass through this per-run gate, including resumed runs.
@MainActor
final class DeviceToolSession {
    private let capabilities: Set<DeviceCapability>
    private let client: DeviceClient
    private let scope: TaskScope
    private let deadline: ContinuousClock.Instant
    private let log: @MainActor (String, String) async throws -> Void
    private let onUnknown: @MainActor () async -> Void
    private var isActive = true
    private var latestFrame: UUID?
    private var isExecuting = false
    private(set) var hasStartedExecution = false

    init(capabilities: Set<DeviceCapability> = Set(DeviceCapability.allCases), client: DeviceClient, scope: TaskScope, timeoutSeconds: Int,
         log: @escaping @MainActor (String, String) async throws -> Void,
         onUnknown: @escaping @MainActor () async -> Void) {
        self.capabilities = capabilities
        self.client = client; self.scope = scope
        deadline = .now.advanced(by: .seconds(timeoutSeconds))
        self.log = log; self.onUnknown = onUnknown
    }

    func stop() { isActive = false; latestFrame = nil }

    var tools: [AgentTool] {
        guard scope != .chat else { return [] }
        var result = [
            tool("device_screenshot", "Observe a fresh screen. Returns an image and frameId with pixel dimensions. Use this frameId for the next touch.", properties: [:], required: [], sideEffect: false),
            tool("device_list_apps", "List installed applications and their exact bundle IDs.", properties: [:], required: [], sideEffect: false)
        ]
        if scope == .control {
            let frame: AgentJSONValue = ["type": "string", "description": "frameId from the most recent screenshot"]
            let coordinate: AgentJSONValue = ["type": "number", "minimum": 0]
            result += [
                tool("device_tap", "Tap a pixel coordinate in the newest screenshot. Observe again afterward.", properties: ["frameId": frame, "x": coordinate, "y": coordinate], required: ["frameId", "x", "y"]),
                tool("device_swipe", "Drag between pixel coordinates. Observe again afterward.", properties: [
                    "frameId": frame, "fromX": coordinate, "fromY": coordinate, "toX": coordinate, "toY": coordinate,
                    "duration": ["type": "number", "minimum": 0.1, "maximum": 2]
                ], required: ["frameId", "fromX", "fromY", "toX", "toY", "duration"]),
                tool("device_type_text", "Enter text into the focused field visible in the latest screenshot. Replaces the system clipboard and pastes it. Observe again afterward.", properties: [
                    "frameId": frame, "text": ["type": "string", "maxLength": 4096]
                ], required: ["frameId", "text"]),
                tool("device_launch_app", "Launch an application by exact bundle ID from device_list_apps. Observe the screen to confirm the result.", properties: [
                    "bundleId": ["type": "string", "minLength": 1, "maxLength": 255]
                ], required: ["bundleId"]),
                tool("device_home", "Return to the device home screen. Observe again afterward.", properties: [:], required: [])
            ]
            result.append(tool("device_press_key", "Send one supported keyboard action. search requests system search (Command-Space), enter confirms the visible focused item, escape dismisses the visible panel. Observe again after every action: a receipt does not prove a shortcut took effect. Only type an app's display name after a fresh screenshot confirms the search field. If a shortcut had no visible effect, navigate using visible controls, such as the AssistiveTouch menu and its Home button, instead of repeating it. Only use tools actually provided. This cannot launch by bundle ID.", properties: [
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
        return result.filter { requirements[$0.name].map { capabilities.contains($0) } ?? false }
    }

    private func tool(_ name: String, _ description: String, properties: [String: AgentJSONValue], required: [String], sideEffect: Bool = true) -> AgentTool {
        AgentTool(name: name, description: description, parameters: [
            "type": "object", "properties": .object(properties),
            "required": .array(required.map { .string($0) }), "additionalProperties": false
        ], mayHaveSideEffects: sideEffect) { [weak self] arguments in
            guard let self else { throw ToolGateError.stopped }
            return try await self.execute(name, arguments: arguments, sideEffect: sideEffect)
        }
    }

    private func execute(_ name: String, arguments: AgentJSONValue, sideEffect: Bool) async throws -> AgentToolResult {
        try check(sideEffect: sideEffect)
        guard !isExecuting else { throw ToolGateError.busy }
        isExecuting = true
        hasStartedExecution = true
        defer { isExecuting = false }
        // Persist a redacted intent before crossing the device-send boundary.
        try await log(sideEffect ? "action.prepared" : "observation.prepared", name)
        try check(sideEffect: sideEffect)
        var actionReturned = false
        do {
            switch name {
            case "device_screenshot":
                let image = try await client.captureScreenshot()
                try check(sideEffect: false)
                latestFrame = image.frameID
                try await log("observation.captured", "width=\(image.width);height=\(image.height);frame=\(image.frameID.uuidString)")
                return .image(image.data, mimeType: image.mimeType,
                              caption: "frameId=\(image.frameID.uuidString); width=\(image.width); height=\(image.height); capturedAt=\(image.capturedAt.ISO8601Format()). Coordinates are image pixels. A frame may be used for one action.")
            case "device_list_apps":
                let apps = try await client.listApplications()
                return .text(apps.map { "\($0.name): \($0.bundleID)" }.joined(separator: "\n"))
            case "device_tap":
                let id = try consumeFrame(arguments)
                let point = DevicePoint(x: try number("x", arguments), y: try number("y", arguments))
                try await log("action.dispatched", name)
                try check(sideEffect: true)
                try await client.tap(at: point, frameID: id)
            case "device_swipe":
                let id = try consumeFrame(arguments)
                let duration = try number("duration", arguments)
                guard (0.1...2).contains(duration) else { throw ToolGateError.arguments }
                let from = DevicePoint(x: try number("fromX", arguments), y: try number("fromY", arguments))
                let to = DevicePoint(x: try number("toX", arguments), y: try number("toY", arguments))
                try await log("action.dispatched", name)
                try check(sideEffect: true)
                try await client.swipe(from: from, to: to, duration: .seconds(duration), frameID: id)
            case "device_type_text":
                let id = try consumeFrame(arguments)
                guard let text = arguments["text"]?.stringValue, !text.isEmpty, text.count <= 4096 else { throw ToolGateError.arguments }
                try await log("action.dispatched", name)
                try check(sideEffect: true)
                try await client.typeText(text, frameID: id)
            case "device_launch_app":
                guard let bundle = arguments["bundleId"]?.stringValue, !bundle.isEmpty, bundle.count <= 255 else { throw ToolGateError.arguments }
                latestFrame = nil
                try await log("action.dispatched", name)
                try check(sideEffect: true)
                try await client.launchApplication(bundleID: bundle)
            case "device_home":
                latestFrame = nil
                try await log("action.dispatched", name)
                try check(sideEffect: true)
                try await client.home()
            case "device_press_key":
                let id = try consumeFrame(arguments)
                guard let raw = arguments["key"]?.stringValue, let key = DeviceKeyboardAction(rawValue: raw) else { throw ToolGateError.arguments }
                try await log("action.dispatched", name)
                try check(sideEffect: true)
                try await client.pressKey(key, frameID: id)
            default: throw ToolGateError.scope
            }
            actionReturned = true
            try await log("action.acknowledged", name)
            return .text("Action submitted. This is not proof of business success. Take a fresh screenshot to verify.")
        } catch let error as DeviceControlError where error.isDeliveryUnknown {
            isActive = false; latestFrame = nil
            // Schedule stop even when persisting the uncertainty itself fails.
            Task { await onUnknown() }
            try? await log("action.unknown", name)
            throw error
        } catch {
            if actionReturned {
                isActive = false; latestFrame = nil
                Task { await onUnknown() }
            }
            throw error
        }
    }

    private func consumeFrame(_ arguments: AgentJSONValue) throws -> UUID {
        guard let raw = arguments["frameId"]?.stringValue, let id = UUID(uuidString: raw), id == latestFrame else {
            throw ToolGateError.frame
        }
        latestFrame = nil
        return id
    }

    private func number(_ key: String, _ value: AgentJSONValue) throws -> Double {
        guard let number = value[key]?.doubleValue, number.isFinite, number >= 0 else { throw ToolGateError.arguments }
        return number
    }

    private func check(sideEffect: Bool) throws {
        guard isActive, !Task.isCancelled else { throw ToolGateError.stopped }
        guard .now < deadline else { isActive = false; throw ToolGateError.expired }
        guard scope != .chat, !sideEffect || scope == .control else { throw ToolGateError.scope }
    }
}

private enum ToolGateError: LocalizedError {
    case stopped, expired, scope, frame, arguments, busy
    var errorDescription: String? {
        switch self {
        case .stopped: String(localized: "toolError.stopped")
        case .expired: String(localized: "toolError.expired")
        case .scope: String(localized: "toolError.scope")
        case .frame: String(localized: "toolError.frame")
        case .arguments: String(localized: "toolError.arguments")
        case .busy: String(localized: "toolError.busy")
        }
    }
}
