#if DEBUG
import SwiftUI
import UIKit
import Network
import CoreBluetooth

struct BLEDeviceCheckView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BLEDeviceCheckController { BLEDeviceCheckController() }
    func updateUIViewController(_ controller: BLEDeviceCheckController, context: Context) {}
}

/// The only evidence of input is UIKit observation. No screenshots, test runner,
/// private device services, synthetic events, or programmatic button activation.
@MainActor final class BLEDeviceCheckController: UIViewController {
    private enum Failure: String, Error {
        case inactive, textNotObserved, pointerPositionUnavailable, pointerDidNotReachTarget
        case clickNotObserved, invalidLayout
    }
    private let field = UITextField()
    private let target = UIButton(type: .system)
    private let status = UILabel()
    private var client: BLEBoardCheckClient?
    private var runTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var path = [String: Any]()
    private var report: [String: Any] = [
        "version": 1, "transport": "ble", "state": "started", "phase": "fixture",
        "networkDeviceBackendUsed": false, "syntheticInputUsed": false,
        "textVerified": false, "clickVerified": false,
        "hidPairingVerified": false, "internetCheckPassed": false
    ]
    private var stages: [[String: Any]] = []
    private var inputInFlight = false
    private var clickArmed = false
    private var observedClickCount = 0
    private var observedText = ""
    private var hoverPoint: CGPoint?
    private var hoverTime: Date?
    private var initialOrientation = UIInterfaceOrientation.unknown
    private var initialBounds = CGRect.zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        report["startedAt"] = Date().timeIntervalSince1970
        report["runID"] = UUID().uuidString
        let title = UILabel()
        title.text = label("bleCheck.title"); title.font = .preferredFont(forTextStyle: .title2)
        title.textAlignment = .center
        let instruction = UILabel()
        instruction.text = label("bleCheck.instruction"); instruction.numberOfLines = 0
        instruction.font = .preferredFont(forTextStyle: .body)
        field.borderStyle = .roundedRect
        field.placeholder = label("bleCheck.field")
        field.autocorrectionType = .no; field.spellCheckingType = .no
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .none; field.smartQuotesType = .no
        field.smartDashesType = .no; field.smartInsertDeleteType = .no
        // Keep the target visible; external HID key events still use UITextInput.
        field.inputView = UIView(frame: .zero)
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        target.setTitle(label("bleCheck.target"), for: .normal)
        target.titleLabel?.font = .preferredFont(forTextStyle: .title1)
        target.backgroundColor = .secondarySystemBackground
        target.layer.cornerRadius = 24
        target.addTarget(self, action: #selector(targetActivated(_:event:)), for: .touchUpInside)
        status.numberOfLines = 0; status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel; status.text = label("bleCheck.waiting")
        let stack = UIStackView(arrangedSubviews: [title, instruction, field, target, status])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            field.heightAnchor.constraint(equalToConstant: 46),
            target.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.3)
        ])
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(pointerMoved(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        save()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard runTask == nil else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kinds = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other]
                .filter { path.usesInterfaceType($0) }.map { String(describing: $0) }
            let satisfied = path.status == .satisfied
            let reason = path.status == .unsatisfied ? String(describing: path.unsatisfiedReason) : "none"
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.path = ["satisfied": satisfied, "interfaceTypes": kinds, "unsatisfiedReason": reason]
                report["networkPath"] = self.path
                save()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "org.eiscue.ble-check.path"))
        runTask = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else {
            finish(state: "failed", reason: "ui_testing_not_allowed"); return
        }
        do {
            try await waitForForeground()
            report["bluetoothAuthorizationBefore"] = authorizationName()
            phase("bluetooth_permission_or_connection")
            let client = BLEBoardCheckClient()
            self.client = client
            client.onStage = { [weak self] stage in
                self?.report["bluetoothAuthorization"] = self?.authorizationName()
                self?.phase(stage)
            }
            try await client.connect()
            report["gattConnected"] = true
            try await waitForForeground()
            networkTask = Task { [weak self] in await self?.checkInternet() }

            // Allow system HID discovery/subscription to finish before any input.
            phase("waiting_for_pairing")
            let deadline = Date().addingTimeInterval(30)
            while true {
                try await waitForForeground()
                do {
                    let receipt = try await client.command(0, pairingHandshake: true)
                    record(receipt)
                    report["encryptedGATT"] = receipt.encrypted
                    break
                } catch BLEBoardCheckClient.Failure.notEncrypted where Date() < deadline {
                    try await Task.sleep(for: .milliseconds(500))
                } catch BLEBoardCheckClient.Failure.hidNotSubscribed where Date() < deadline {
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            try await waitForForeground()
            phase("waiting_for_hid_subscription")
            try await Task.sleep(for: .seconds(2))
            try requireVisible()
            guard let scene = view.window?.windowScene else { throw Failure.invalidLayout }
            initialOrientation = scene.effectiveGeometry.interfaceOrientation
            initialBounds = view.bounds
            inputInFlight = true
            // Digits avoid depending on the user's English/Pinyin keyboard mode;
            // this first probe proves ASCII HID delivery, not Unicode support.
            let expected = String(UInt64.random(in: 100_000_000_000...999_999_999_999))
            guard field.becomeFirstResponder() else { throw Failure.invalidLayout }
            phase("keyboard_input")
            for byte in expected.utf8 {
                try requireVisible()
                record(try await client.command(3, payload: [byte]))
                // One command per key. Never replay a key with uncertain outcome.
                try await Task.sleep(for: .milliseconds(90))
            }
            try await wait(seconds: 5) { self.observedText == expected }
            guard observedText == expected else { throw Failure.textNotObserved }
            report["textVerified"] = true
            report["observedTextLength"] = observedText.count
            report["hidPairingVerified"] = true
            field.resignFirstResponder()
            phase("pointer_observation")
            hoverPoint = nil; hoverTime = nil
            record(try await client.move(dx: 1, dy: 0))
            try await wait(seconds: 3) { self.hoverPoint != nil }
            if hoverPoint == nil,
               ProcessInfo.processInfo.arguments.contains("--ble-pointer-coverage-check") {
                try await verifyCoverageClick(using: client)
            } else {
                guard hoverPoint != nil else { throw Failure.pointerPositionUnavailable }
                // Relative HID movement has no guaranteed pixel scale. Observe each
                // move in UIKit and stop if its actual position cannot be established.
                for _ in 0..<24 {
                    try requireVisible()
                    guard let point = hoverPoint, let time = hoverTime, Date().timeIntervalSince(time) < 3 else {
                        throw Failure.pointerPositionUnavailable
                    }
                    let rect = target.convert(target.bounds, to: view).insetBy(dx: 24, dy: 24)
                    if rect.contains(point) { break }
                    let dx = Int16(max(-40, min(40, (rect.midX - point.x) / 3)))
                    let dy = Int16(max(-40, min(40, (rect.midY - point.y) / 3)))
                    hoverTime = nil
                    record(try await client.move(dx: dx, dy: dy))
                    try await wait(seconds: 2) { self.hoverTime != nil }
                }
                try requireVisible()
                guard let point = hoverPoint, let time = hoverTime, Date().timeIntervalSince(time) < 3,
                      target.convert(target.bounds, to: view).insetBy(dx: 24, dy: 24).contains(point) else {
                    throw Failure.pointerDidNotReachTarget
                }
                report["pointerObservedInsideTarget"] = true
                report["clickValidation"] = "hover_observed_target"
                phase("pointer_click")
                clickArmed = true
                record(try await client.command(2, payload: [1, 1]))
                try await wait(seconds: 5) { self.observedClickCount == 1 }
                clickArmed = false
                guard observedClickCount == 1 else { throw Failure.clickNotObserved }
            }
            report["clickVerified"] = true
            phase("releasing_hid")
            record(try await client.command(0))
            inputInFlight = false
            client.disconnect()
            report["locallyDisconnected"] = true
            finish(state: "passed", reason: "uikit_observed_keyboard_and_pointer")
        } catch {
            clickArmed = false; inputInFlight = false
            // Stop only releases reports. It never synthesizes a target action.
            if let client { _ = try? await client.command(0); client.disconnect() }
            let reason = (error as? Failure)?.rawValue ?? (error as? BLEBoardCheckClient.Failure)?.rawValue ?? "cancelled"
            let needsAction = ["bluetoothDenied", "bluetoothUnavailable", "notEncrypted", "hidNotSubscribed", "pointerPositionUnavailable"]
            report["requiresUserAction"] = needsAction.contains(reason)
            // Lack of UIKit hover on iPhone says nothing about HID mouse support.
            // Preserve separately verified keyboard input as a partial result.
            let state = report["textVerified"] as? Bool == true ? "partial_pass" :
                (needsAction.contains(reason) ? "needs_user_action" : "failed")
            finish(state: state, reason: reason)
        }
    }

    /// Separately opted-in transport check, never a coordinate calibration. The
    /// entire owned safe area becomes one harmless target, and only one click is
    /// sent. No additional movement, edge search, retries, or navigation occurs.
    private func verifyCoverageClick(using client: BLEBoardCheckClient) async throws {
        guard report["textVerified"] as? Bool == true, hoverPoint == nil,
              observedClickCount == 0,
              ProcessInfo.processInfo.arguments.contains("--ble-pointer-coverage-check") else {
            throw Failure.pointerPositionUnavailable
        }
        try requireVisible()
        let coverage = UIButton(type: .system)
        coverage.translatesAutoresizingMaskIntoConstraints = false
        coverage.backgroundColor = .secondarySystemBackground
        coverage.setTitle(label("bleCheck.coverageTarget"), for: .normal)
        coverage.titleLabel?.font = .preferredFont(forTextStyle: .title2)
        coverage.titleLabel?.numberOfLines = 0
        coverage.titleLabel?.textAlignment = .center
        coverage.addTarget(self, action: #selector(targetActivated(_:event:)), for: .touchUpInside)
        view.addSubview(coverage)
        NSLayoutConstraint.activate([
            coverage.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            coverage.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            coverage.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            coverage.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        view.layoutIfNeeded()
        let bounds = coverage.convert(coverage.bounds, to: view)
        guard !bounds.isEmpty, view.bounds.contains(bounds) else { throw Failure.invalidLayout }
        phase("pointer_coverage_layout")
        try await Task.sleep(for: .milliseconds(300))
        try requireVisible()
        view.layoutIfNeeded()
        guard bounds == coverage.convert(coverage.bounds, to: view) else { throw Failure.invalidLayout }
        report["clickValidation"] = "full_fixture_target_without_hover"
        report["absoluteCoordinatesVerified"] = false
        report["targetBounds"] = rectSummary(bounds)
        report["coordinateSpace"] = "fixture_view_points"
        phase("pointer_coverage_single_click")
        try requireVisible()
        clickArmed = true
        defer { clickArmed = false }
        record(try await client.command(2, payload: [1, 1]))
        try await wait(seconds: 5) { self.observedClickCount == 1 }
        try requireVisible()
        guard observedClickCount == 1 else { throw Failure.clickNotObserved }
    }

    private func rectSummary(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY),
         "width": Double(rect.width), "height": Double(rect.height)]
    }

    private func waitForForeground() async throws {
        try await wait(seconds: 90) { self.view.window?.windowScene?.activationState == .foregroundActive }
        try requireVisible(checkGeometry: false)
    }

    private func requireVisible(checkGeometry: Bool = true) throws {
        try Task.checkCancellation()
        guard isViewLoaded, view.window?.windowScene?.activationState == .foregroundActive,
              UIApplication.shared.applicationState == .active else { throw Failure.inactive }
        if checkGeometry, inputInFlight {
            guard view.bounds == initialBounds,
                  view.window?.windowScene?.effectiveGeometry.interfaceOrientation == initialOrientation else { throw Failure.invalidLayout }
        }
    }

    private func wait(seconds: Double, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
    }

    @objc private func textChanged() {
        // Capture only a bounded fixture result, never arbitrary user text in logs.
        observedText = String((field.text ?? "").prefix(64))
    }
    @objc private func pointerMoved(_ gesture: UIHoverGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed {
            hoverPoint = gesture.location(in: view); hoverTime = Date()
        } else { hoverPoint = nil; hoverTime = nil }
    }
    @objc private func targetActivated(_ sender: UIButton, event: UIEvent?) {
        guard clickArmed, inputInFlight, (try? requireVisible()) != nil,
              let touches = event?.allTouches, !touches.isEmpty,
              touches.contains(where: { sender.bounds.contains($0.location(in: sender)) }) else { return }
        observedClickCount += 1
        report["observedClickCount"] = observedClickCount
        report["observedTouchTypes"] = Array(Set(touches.map { $0.type.rawValue })).sorted()
        report["observedTouchLocations"] = touches.map { touch in
            let point = touch.location(in: view)
            return ["x": Double(point.x), "y": Double(point.y), "type": Double(touch.type.rawValue)]
        }
        report["targetBounds"] = rectSummary(sender.convert(sender.bounds, to: view))
        report["coordinateSpace"] = "fixture_view_points"
        sender.setTitle(label("bleCheck.clicked"), for: .normal)
        save()
    }

    @objc private func resignedActive() {
        guard inputInFlight else { return } // System pairing prompts may precede input.
        clickArmed = false
        runTask?.cancel()
        client?.disconnect()
    }

    private func phase(_ value: String) {
        report["phase"] = value
        report["assistiveTouchRunning"] = UIAccessibility.isAssistiveTouchRunning
        if stages.count < 80 { stages.append(["phase": value, "time": Date().timeIntervalSince1970]) }
        status.text = label("bleCheck.waiting") + "\n" + value
        save()
    }
    private func record(_ receipt: BLEBoardCheckClient.Receipt) {
        report["lastAcknowledgedOpcode"] = receipt.opcode
        report["lastAcknowledgedRequest"] = receipt.requestID
        report["lastEmittedReportCount"] = receipt.emittedReports
        report["encryptedGATT"] = receipt.encrypted
        save()
    }
    private func finish(state: String, reason: String) {
        report["state"] = state; report["reason"] = reason
        report["lastPhase"] = report["phase"]; report["phase"] = "finished"
        report["finishedAt"] = Date().timeIntervalSince1970
        status.text = label(state == "passed" ? "bleCheck.passed" : "bleCheck.stopped") + "\n" + reason
        save()
    }
    private func authorizationName() -> String {
        switch CBManager.authorization {
        case .notDetermined: "not_determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .allowedAlways: "allowed"
        @unknown default: "unknown"
        }
    }

    private func checkInternet() async {
        // No model credentials, cookies, SSIDs, addresses, or response body logs.
        guard (path["interfaceTypes"] as? [String])?.contains("wifi") == true else {
            report["internetCheck"] = "skipped_no_wifi_path"; save(); return
        }
        report["internetCheck"] = "started_wifi_path"
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false; config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 8
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: URL(string: "https://www.apple.com/library/test/success.html")!)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            report["internetHTTPStatus"] = code
            report["internetCheckPassed"] = code == 200
            report["internetCheck"] = "finished_cellular_disabled"
            report["internetCheckEndPath"] = path
        } catch {
            report["internetCheck"] = "failed_cellular_disabled"
            report["internetErrorCode"] = (error as NSError).code
        }
        save()
    }

    private func save() {
        report["stages"] = stages
        let destination = URL.cachesDirectory.appendingPathComponent("EiscueBLEDeviceCheck.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ble-check-\(UUID().uuidString).json")
            let files = FileManager.default
            guard files.createFile(atPath: temporary.path, contents: data,
                                   attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? files.removeItem(at: temporary) }
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else { try files.moveItem(at: temporary, to: destination) }
        } catch { status.text = label("bleCheck.reportFailed") }
    }
    private func label(_ key: String) -> String { NSLocalizedString(key, tableName: "BLEDeviceCheck", comment: "Debug-only Bluetooth check") }

    deinit {
        pathMonitor.cancel()
        runTask?.cancel(); networkTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
#endif
