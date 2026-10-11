#if DEBUG
import SwiftUI
import EiscueDeviceKit
import UIKit
import ImageIO

/// Deterministic, opt-in target in the normal App process. No Runner App,
/// external model request, credential export or programmatic button invocation.
@MainActor @Observable final class OwnedDeviceCheckState {
    static let shared = OwnedDeviceCheckState()
    var count = 0
    var button = CGRect.zero
    var scroll = CGRect.zero
    var field = CGRect.zero
    var layout = CGRect.zero
    var input = ""
    var rowY: CGFloat = 0
    var phase = "Waiting"
    @ObservationIgnored weak var window: UIWindow?
    var screenBounds = CGRect.zero
    var windowBounds = CGRect.zero
    var screenScale: CGFloat = 0
    var orientation = UIInterfaceOrientation.unknown

    func observeWindow(_ window: UIWindow?) {
        self.window = window
        let scene = window?.windowScene
        let screenBounds = scene?.screen.bounds ?? .zero, windowBounds = window?.bounds ?? .zero
        let scale = scene?.screen.scale ?? 0, orientation = scene?.effectiveGeometry.interfaceOrientation ?? .unknown
        if self.screenBounds != screenBounds { self.screenBounds = screenBounds }
        if self.windowBounds != windowBounds { self.windowBounds = windowBounds }
        if screenScale != scale { screenScale = scale }
        if self.orientation != orientation { self.orientation = orientation }
    }
}

private struct OwnedWindowProbe: UIViewRepresentable {
    let proof: OwnedDeviceCheckState
    func makeUIView(context: Context) -> WindowView {
        let view = WindowView()
        view.isUserInteractionEnabled = false
        view.proof = proof
        return view
    }
    func updateUIView(_ view: WindowView, context: Context) { view.proof = proof }
    final class WindowView: UIView {
        weak var proof: OwnedDeviceCheckState?
        override func didMoveToWindow() { super.didMoveToWindow(); publishWindow() }
        override func layoutSubviews() { super.layoutSubviews(); publishWindow() }
        private func publishWindow() {
            // Publish outside SwiftUI's current layout pass. Read the attached
            // window again when delivered so a departed scene cannot overwrite it.
            Task { @MainActor [weak self] in
                guard let self else { return }
                proof?.observeWindow(window)
            }
        }
    }
}
private struct ProbeFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
private extension View {
    func probeFrame(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ProbeFrames.self, value: [name: geometry.frame(in: .global)])
        })
    }
}
struct OwnedDeviceCheckView: View {
    @State private var proof = OwnedDeviceCheckState.shared
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 450
            VStack(spacing: compact ? 8 : 24) {
                Text("probe.title").font(compact ? .headline : .title2)
                Text("probe.count \(proof.count)").font((compact ? Font.title2 : .largeTitle).monospacedDigit())
                Button("probe.increment") { proof.count += 1 }
                    .buttonStyle(.borderedProminent).controlSize(compact ? .regular : .large).probeFrame("button")
                TextField("probe.inputPlaceholder", text: $proof.input)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().probeFrame("field")
                ScrollView {
                    VStack(spacing: 28) {
                        ForEach(1...20, id: \.self) { index in
                            Text("probe.row \(index)").frame(maxWidth: .infinity)
                                .probeFrame(index == 1 ? "row" : "unused")
                        }
                    }.padding()
                }.frame(height: compact ? 80 : 230).background(.secondary.opacity(0.06)).probeFrame("scroll")
                Text(proof.phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(compact ? 12 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .probeFrame("layout")
        }
        .background(OwnedWindowProbe(proof: proof))
        .onPreferenceChange(ProbeFrames.self) { frames in
            Task { @MainActor in
                if let rect = frames["button"] { proof.button = rect }
                if let rect = frames["scroll"] { proof.scroll = rect }
                if let rect = frames["field"] { proof.field = rect }
                if let rect = frames["layout"] { proof.layout = rect }
                if let rect = frames["row"] { proof.rowY = rect.minY }
            }
        }
    }
}

@MainActor private struct OwnedSceneGeometry {
    let window: UIWindow
    let scene: UIWindowScene
    let screenBounds: CGRect
    let windowBounds: CGRect
    let scale: CGFloat
    let orientation: UIInterfaceOrientation
    let button: CGRect
    let scroll: CGRect
    let field: CGRect
    let layout: CGRect
    let rowY: CGFloat

    init(proof: OwnedDeviceCheckState, orientation expected: UIInterfaceOrientation? = nil) throws {
        guard let window = proof.window, let scene = window.windowScene,
              scene.activationState == .foregroundActive,
              scene.effectiveGeometry.interfaceOrientation != .unknown,
              expected == nil || scene.effectiveGeometry.interfaceOrientation == expected,
              proof.orientation == scene.effectiveGeometry.interfaceOrientation,
              proof.screenBounds == scene.screen.bounds, proof.windowBounds == window.bounds,
              proof.screenScale == scene.screen.scale, scene.screen.scale > 0,
              !scene.screen.bounds.isEmpty, !window.bounds.isEmpty,
              !proof.layout.isEmpty,
              abs(proof.layout.width - (window.bounds.width - window.safeAreaInsets.left - window.safeAreaInsets.right)) <= 1,
              [proof.button, proof.scroll, proof.field].allSatisfy({
                  !$0.isEmpty && window.bounds.insetBy(dx: -1, dy: -1).contains($0)
              }) else { throw DeviceControlError.invalidCoordinates }
        self.window = window; self.scene = scene
        screenBounds = scene.screen.bounds; windowBounds = window.bounds
        scale = scene.screen.scale; orientation = scene.effectiveGeometry.interfaceOrientation
        button = proof.button; scroll = proof.scroll; field = proof.field
        layout = proof.layout; rowY = proof.rowY
    }

    func matches(_ other: Self) -> Bool {
        window === other.window && scene === other.scene && screenBounds == other.screenBounds &&
        windowBounds == other.windowBounds && scale == other.scale && orientation == other.orientation &&
        button == other.button && scroll == other.scroll && field == other.field && layout == other.layout && rowY == other.rowY
    }

    func changedGeometryNames(comparedTo other: Self) -> [String] {
        let differences: [(String, Bool)] = [
            ("window", window !== other.window), ("scene", scene !== other.scene),
            ("screenBounds", screenBounds != other.screenBounds), ("windowBounds", windowBounds != other.windowBounds),
            ("scale", scale != other.scale), ("orientation", orientation != other.orientation),
            ("button", button != other.button), ("scroll", scroll != other.scroll), ("field", field != other.field),
            ("layout", layout != other.layout), ("rowY", rowY != other.rowY),
        ]
        return differences.compactMap { $0.1 ? $0.0 : nil }
    }

    func point(_ point: CGPoint, frame: DeviceScreenshot) throws -> DevicePoint {
        let screenPoint = window.convert(point, to: scene.screen.coordinateSpace)
        guard screenPoint.x.isFinite, screenPoint.y.isFinite, screenBounds.contains(screenPoint) else {
            throw DeviceControlError.invalidCoordinates
        }
        return DevicePoint(x: Double((screenPoint.x - screenBounds.minX) / screenBounds.width) * Double(frame.width),
                           y: Double((screenPoint.y - screenBounds.minY) / screenBounds.height) * Double(frame.height))
    }

    func validatePNG(_ frame: DeviceScreenshot) throws {
        guard frame.mimeType == "image/png", frame.data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(frame.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == frame.width, height == frame.height,
              abs(CGFloat(width) - screenBounds.width * scale) <= 1,
              abs(CGFloat(height) - screenBounds.height * scale) <= 1,
              (width > height) == orientation.isLandscape else {
            throw DeviceControlError.connection("Owned PNG did not match the current scene orientation and screen bounds")
        }
    }
}

@MainActor private final class OwnedGeometryRequest {
    var error: Error?
    nonisolated func errorHandler() -> @Sendable (Error) -> Void {
        { @Sendable [weak self] error in
            Task { @MainActor [weak self] in self?.error = error }
        }
    }
}

extension AppModel {
    private func ownedGeometry(_ proof: OwnedDeviceCheckState, orientation: UIInterfaceOrientation? = nil,
                               request: OwnedGeometryRequest? = nil) async throws -> OwnedSceneGeometry {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var previous: OwnedSceneGeometry?, stableSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            if let error = request?.error { throw error }
            // A 180° rotation keeps the same dimensions and may not trigger
            // layoutSubviews. Read the attached window's actual scene geometry
            // on every poll instead of waiting for a layout callback to refresh it.
            proof.observeWindow(proof.window)
            if let current = try? OwnedSceneGeometry(proof: proof, orientation: orientation) {
                if let previous, previous.matches(current) {
                    if let stableSince, stableSince.duration(to: .now) >= .milliseconds(200) { return current }
                } else { stableSince = .now }
                previous = current
            } else { previous = nil; stableSince = nil }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DeviceControlError.connection("Owned window geometry did not settle in the requested orientation")
    }

    private func ownedCapture(_ proof: OwnedDeviceCheckState, orientation: UIInterfaceOrientation? = nil) async throws
        -> (frame: DeviceScreenshot, geometry: OwnedSceneGeometry) {
        // Only repeat observation when SwiftUI geometry moved during capture.
        // Native capture failures propagate immediately; no input is replayed.
        for _ in 0..<3 {
            let before = try await ownedGeometry(proof, orientation: orientation)
            let frame = try await deviceClient.captureScreenshot()
            proof.observeWindow(proof.window)
            let after = try OwnedSceneGeometry(proof: proof, orientation: orientation)
            guard before.matches(after) else {
                print("Owned capture changed geometry: \(before.changedGeometryNames(comparedTo: after).joined(separator: ","))")
                continue
            }
            try after.validatePNG(frame)
            return (frame, after)
        }
        throw DeviceControlError.staleFrame
    }

    private func ownedRotate(_ proof: OwnedDeviceCheckState, scene: UIWindowScene,
                             orientation: UIInterfaceOrientation) async throws -> OwnedSceneGeometry {
        guard proof.window?.windowScene === scene, scene.activationState == .foregroundActive else {
            throw DeviceControlError.connection("Owned window left its foreground scene")
        }
        let mask: UIInterfaceOrientationMask
        switch orientation {
        case .portrait: mask = .portrait
        case .portraitUpsideDown: mask = .portraitUpsideDown
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        default: throw DeviceControlError.invalidCoordinates
        }
        let request = OwnedGeometryRequest()
        proof.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask), errorHandler: request.errorHandler())
        let geometry = try await ownedGeometry(proof, orientation: orientation, request: request)
        guard geometry.scene === scene else { throw DeviceControlError.connection("Owned rotation moved to another scene") }
        return geometry
    }

    func runOwnedDeviceCheck(method: DeviceConnectionMethod = .localVPN) async {
        let proof = OwnedDeviceCheckState.shared
        let destination = URL.cachesDirectory.appendingPathComponent("EiscueOwnedDeviceCheck.json")
        var report: [String: Any] = ["version": 3, "state": "started", "phase": "preparation",
            "connectionMethod": method.rawValue, "localTunnelConnectedAtStart": localTunnel.isConnected]
        var orientationToRestore: (scene: UIWindowScene, orientation: UIInterfaceOrientation)?
        func save(_ phase: String) {
            proof.phase = phase; report["phase"] = phase
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
            try? data.write(to: destination, options: [.atomic, .completeFileProtection])
        }
        save("preparation")
        do {
            // Use only an already saved identity. This route never imports,
            // exports or replaces pairing credentials. Wireless never starts
            // or resumes a local VPN.
            let hasIdentity = try await deviceClient.hasPairingIdentity()
            report["identitySaved"] = hasIdentity
            guard hasIdentity else { throw DeviceControlError.noIdentity }
            if method == .localVPN {
                save("tunnel")
                if !localTunnel.isConnected, ProcessInfo.processInfo.arguments.contains("--resume-existing-local-tunnel") {
                    try await localTunnel.resumeExistingForDiagnostics()
                }
                guard localTunnel.isConnected else { throw DeviceControlError.notConnected }
            } else {
                save("select_connection")
                try await localTunnel.refresh()
                report["localTunnelConnectedAtStart"] = localTunnel.isConnected
                // Reuse the production switch flow and retain the user's
                // explicitly requested board method for subsequent manual use.
                await selectDeviceConnectionMethod(method)
                guard deviceConnectionMethod == method else { throw DeviceControlError.busy }
                // A stale owned tunnel may exist even when the saved method was
                // already wireless. Stop only Eiscue's provider configuration.
                if localTunnel.isConnected || localTunnel.isTransitioning {
                    save("stop_owned_tunnel")
                    await stopLocalTunnel()
                }
                try await localTunnel.refresh()
                guard !localTunnel.isConnected, !localTunnel.isTransitioning else {
                    throw DeviceControlError.connection("Eiscue's local VPN has not stopped; wireless verification was not started")
                }
                report["selectedConnectionMethod"] = deviceConnectionMethod.rawValue
                report["connectionSelectionRetained"] = true
            }
            // Require the native target's attached scene and settled view frames.
            save("geometry")
            _ = try await ownedGeometry(proof)
            for cycle in 1...2 {
                if method != .localVPN {
                    save("verify_board_route_\(cycle)")
                    try await localTunnel.refresh()
                    report["localTunnelConnectedAtConnect_\(cycle)"] = localTunnel.isConnected
                    guard deviceConnectionMethod == method, !localTunnel.isConnected, !localTunnel.isTransitioning else {
                        throw DeviceControlError.connection("The selected board route changed; wireless verification was stopped")
                    }
                }
                save("connect_\(cycle)")
                // The same entry point used by AppModel.connectDevice. Board
                // discovery is not success: this returns only after production
                // identity verification, developer readiness and media startup.
                try await deviceClient.connect(method: method)
                guard case .ready(let capabilities) = await deviceClient.status() else {
                    throw DeviceControlError.notConnected
                }
                report["capabilities_\(cycle)"] = capabilities.map(\.rawValue).sorted()
                report["connected_\(cycle)"] = true
                save("screenshot_\(cycle)")
                let capture = try await ownedCapture(proof)
                let frame = capture.frame
                try frame.data.write(to: URL.cachesDirectory.appendingPathComponent("EiscueOwnedDeviceFrame.png"), options: [.atomic, .completeFileProtection])
                report["width"] = frame.width; report["height"] = frame.height; report["mimeType"] = frame.mimeType
                let before = proof.count
                save("tap_\(cycle)")
                try await deviceClient.tap(at: capture.geometry.point(CGPoint(x: capture.geometry.button.midX, y: capture.geometry.button.midY), frame: frame), frameID: frame.frameID)
                try await Task.sleep(for: .milliseconds(400))
                guard proof.count == before + 1 else { throw DeviceControlError.connection("Owned button did not increment") }
                report["tapVerified_\(cycle)"] = true
                let afterTap = try await ownedCapture(proof)
                report["postTapScreenshot_\(cycle)"] = !afterTap.frame.data.isEmpty
                if cycle == 1 {
                    let original = afterTap.geometry
                    orientationToRestore = (original.scene, original.orientation)
                    save("rotate_landscape_left")
                    _ = try await ownedRotate(proof, scene: original.scene, orientation: .landscapeLeft)
                    // This observation remains unused until after the 180° turn.
                    // Capturing again before testing it would invalidate the
                    // ledger by replacement and would not test rotation guards.
                    let left = try await ownedCapture(proof, orientation: .landscapeLeft)
                    let rotationCount = proof.count
                    let oldPoint = try left.geometry.point(CGPoint(x: left.geometry.button.midX, y: left.geometry.button.midY), frame: left.frame)
                    save("rotate_landscape_right")
                    let rightGeometry = try await ownedRotate(proof, scene: original.scene, orientation: .landscapeRight)
                    guard rightGeometry.screenBounds.size == left.geometry.screenBounds.size,
                          rightGeometry.scale == left.geometry.scale else {
                        throw DeviceControlError.connection("Owned 180 degree rotation changed the screen dimensions")
                    }
                    save("reject_old_orientation_frame")
                    do {
                        try await deviceClient.tap(at: oldPoint, frameID: left.frame.frameID)
                        throw DeviceControlError.connection("Owned old orientation frame was accepted")
                    } catch DeviceControlError.staleFrame {
                        // Require rejection at the API and no visible button effect.
                    }
                    try await Task.sleep(for: .milliseconds(400))
                    guard proof.count == rotationCount else { throw DeviceControlError.connection("Owned stale orientation frame changed the button") }
                    let right = try await ownedCapture(proof, orientation: .landscapeRight)
                    guard right.frame.width == left.frame.width, right.frame.height == left.frame.height else {
                        throw DeviceControlError.connection("Owned opposite landscape PNG dimensions did not match")
                    }
                    save("tap_new_orientation_frame")
                    try await deviceClient.tap(at: right.geometry.point(CGPoint(x: right.geometry.button.midX, y: right.geometry.button.midY), frame: right.frame), frameID: right.frame.frameID)
                    try await Task.sleep(for: .milliseconds(400))
                    guard proof.count == rotationCount + 1 else { throw DeviceControlError.connection("Owned fresh orientation frame did not increment") }
                    report["rotation180Verified"] = true
                    report["rotation180OldFrameRejectedWithoutEffect"] = true
                    report["rotation180FreshFrameTapVerified"] = true
                    report["rotationLandscapeWidth"] = right.frame.width
                    report["rotationLandscapeHeight"] = right.frame.height
                    save("restore_orientation")
                    _ = try await ownedRotate(proof, scene: original.scene, orientation: original.orientation)
                    orientationToRestore = nil
                    report["originalOrientationRestored"] = true
                    let swipeCapture = try await ownedCapture(proof)
                    let oldY = swipeCapture.geometry.rowY, rect = swipeCapture.geometry.scroll
                    save("swipe")
                    try await deviceClient.swipe(from: swipeCapture.geometry.point(CGPoint(x: rect.midX, y: rect.maxY - 30), frame: swipeCapture.frame),
                        to: swipeCapture.geometry.point(CGPoint(x: rect.midX, y: rect.minY + 30), frame: swipeCapture.frame), frameID: swipeCapture.frame.frameID)
                    try await Task.sleep(for: .milliseconds(500))
                    guard proof.rowY < oldY - 30 else { throw DeviceControlError.connection("Owned scroll did not move") }
                    report["swipeVerified"] = true
                    let fieldCapture = try await ownedCapture(proof)
                    save("focus")
                    try await deviceClient.tap(at: fieldCapture.geometry.point(CGPoint(x: fieldCapture.geometry.field.midX, y: fieldCapture.geometry.field.midY), frame: fieldCapture.frame), frameID: fieldCapture.frame.frameID)
                    try await Task.sleep(for: .milliseconds(300))
                    let typingFrame = try await ownedCapture(proof)
                    save("text")
                    let testText = "你好，Eiscue 🧊"
                    try await deviceClient.typeText(testText, frameID: typingFrame.frame.frameID)
                    try await Task.sleep(for: .milliseconds(400))
                    guard proof.input == testText else { throw DeviceControlError.connection("Owned text input did not match") }
                    report["unicodeTextVerified"] = true
                    save("after_text_screenshot")
                    _ = try await ownedCapture(proof)
                    save("home")
                    try await deviceClient.home()
                    try await Task.sleep(for: .milliseconds(300))
                    guard currentScenePhase == .background else { throw DeviceControlError.connection("Home did not background the App") }
                    report["homeVerified"] = true
                    save("launch")
                    try await deviceClient.launchApplication(bundleID: "org.eiscue.app")
                    let launchDeadline = ContinuousClock.now.advanced(by: .seconds(4))
                    while currentScenePhase != .active, ContinuousClock.now < launchDeadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard currentScenePhase == .active else { throw DeviceControlError.connection("App did not return to foreground") }
                    report["launchVerified"] = true
                    _ = try await ownedCapture(proof)
                }
                save("stop_\(cycle)")
                await deviceClient.disconnect()
                if case .ready = await deviceClient.status() { throw DeviceControlError.connection("Owned connection still ready after stop") }
                // Status no longer ready proves local disconnection only. The
                // public API does not expose a daemon teardown acknowledgement.
                report["locallyDisconnected_\(cycle)"] = true
            }
            report["state"] = "passed"
        } catch {
            report["state"] = "failed"
            report["failedPhase"] = report["phase"]
            report["errorCategory"] = String(describing: type(of: error))
            report["reason"] = error.localizedDescription
            await deviceClient.disconnect()
            if let restoration = orientationToRestore {
                save("restore_orientation_after_failure")
                do {
                    _ = try await ownedRotate(proof, scene: restoration.scene, orientation: restoration.orientation)
                    report["originalOrientationRestored"] = true
                } catch { report["orientationRestore"] = "failed" }
            }
        }
        save("finished")
    }
}
#endif
