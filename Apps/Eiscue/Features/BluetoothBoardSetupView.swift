import EiscueDeviceKit
import SwiftUI
import UIKit

struct BluetoothBoardSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showsValidation = false

    var body: some View {
        VStack(spacing: 18) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    step("1", "bluetooth.connectTitle", complete: model.isBluetoothConnected)
                    if !model.isBluetoothConnected {
                        Text(text("bluetooth.powerDetail")).font(.subheadline).foregroundStyle(.secondary)
                        Text(text("bluetooth.assistiveTouch")).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isBluetoothConnected {
                        Button(text("bluetooth.disconnect")) { Task { await model.disconnectDevice() } }
                            .buttonStyle(.glass)
                    } else {
                        Button { Task { await model.enableDeviceControl() } } label: {
                            HStack {
                                if model.isConnecting { ProgressView() }
                                Text(text(model.isConnecting ? "bluetooth.connecting" : "bluetooth.connectButton"))
                            }
                        }
                        .buttonStyle(.glass).disabled(model.isBusy)
                        .accessibilityIdentifier("bluetoothConnectButton")
                        if model.isConnecting {
                            Button(String(localized: "common.cancel")) { Task { await model.disconnectDevice() } }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    step("2", "bluetooth.shareTitle", complete: model.isBluetoothScreenShared)
                    if !model.isBluetoothScreenShared {
                        Text(text("bluetooth.shareDetail")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if model.isBluetoothScreenShared {
                        Button(text("bluetooth.stopSharing")) {
                            Task {
                                if model.isRunning, model.activeRun?.scope != .chat { await model.stop() }
                                do { try model.bluetoothController.stopSharing() }
                                catch { model.errorMessage = error.localizedDescription }
                                await model.refreshDeviceStatus()
                            }
                        }.buttonStyle(.glass)
                    } else {
                        HStack(spacing: 12) {
                            ScreenBroadcastPicker().frame(width: 52, height: 52)
                                .accessibilityIdentifier("bluetoothScreenShareButton")
                            Text(text("bluetooth.shareButtonHint")).font(.subheadline)
                        }
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    step("3", "bluetooth.verifyTitle", complete: model.isBluetoothPointerVerified)
                    Text(text(model.isBluetoothPointerVerified ? "bluetooth.readyDetail" : "bluetooth.verifyDetail"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button(text(model.isBluetoothPointerVerified ? "bluetooth.verifyAgain" : "bluetooth.verifyButton")) { showsValidation = true }
                        .buttonStyle(.glass)
                        .disabled(!model.isBluetoothConnected || !model.isBluetoothScreenShared || model.isBusy)
                        .accessibilityIdentifier("bluetoothVerifyButton")
                }
            }
            if let error = model.deviceConnectionError {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.primary)
                    .accessibilityIdentifier("bluetoothConnectionError")
            }
        }
        .fullScreenCover(isPresented: $showsValidation, onDismiss: {
            Task { await model.refreshDeviceStatus(); model.bluetoothRevision += 1 }
        }) {
            BluetoothPointerValidation(controller: model.bluetoothController) { showsValidation = false }
                .ignoresSafeArea().interactiveDismissDisabled()
        }
    }

    private func step(_ number: String, _ key: String, complete: Bool) -> some View {
        Label(text(key), systemImage: complete ? "checkmark.circle.fill" : "\(number).circle")
            .font(.headline).foregroundStyle(.primary)
    }
    private func text(_ key: String) -> String { NSLocalizedString(key, tableName: "Bluetooth", comment: "") }
}

private struct BluetoothPointerValidation: UIViewControllerRepresentable {
    let controller: BluetoothDeviceController
    let onClose: () -> Void
    func makeUIViewController(context: Context) -> BluetoothPointerValidationController {
        BluetoothPointerValidationController(controller: controller, onClose: onClose)
    }
    func updateUIViewController(_ uiViewController: BluetoothPointerValidationController, context: Context) {}
}

@MainActor
private final class BluetoothPointerValidationController: UIViewController {
    private let controller: BluetoothDeviceController
    private let onClose: () -> Void
    private let target = UIButton(type: .custom)
    private let status = UILabel()
    private let close = UIButton(type: .system)
    private let field = UITextField()
    private var task: Task<Void, Never>?
    private var touches: [DevicePoint] = []
    private var armed = false
    private var stableBounds = CGRect.zero
    private var stableOrientation = UIInterfaceOrientation.unknown
    private var finished = false

    init(controller: BluetoothDeviceController, onClose: @escaping () -> Void) {
        self.controller = controller; self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        target.backgroundColor = .systemBackground
        target.addTarget(self, action: #selector(observedTouch(_:event:)), for: .touchUpInside)
        target.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(target)
        status.text = text("bluetooth.verifying")
        status.numberOfLines = 0; status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .title2)
        status.isUserInteractionEnabled = false
        view.addSubview(status)
        field.borderStyle = .roundedRect; field.textAlignment = .center
        field.placeholder = text("bluetooth.keyboardCheck")
        field.inputView = UIView(frame: .zero)
        field.inputAssistantItem.leadingBarButtonGroups = []; field.inputAssistantItem.trailingBarButtonGroups = []
        view.addSubview(field)
        close.setTitle(text("bluetooth.cancel"), for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(close)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        target.frame = view.bounds
        status.frame = CGRect(x: 28, y: view.safeAreaInsets.top + 32, width: view.bounds.width - 56, height: 145)
        field.frame = CGRect(x: 36, y: view.bounds.height * 0.44, width: view.bounds.width - 72, height: 48)
        close.frame = CGRect(x: 36, y: view.bounds.height - view.safeAreaInsets.bottom - 62, width: view.bounds.width - 72, height: 48)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        task?.cancel()
        if !finished { Task { await controller.cancelCalibration() } }
    }
    @objc private func observedTouch(_ button: UIButton, event: UIEvent) {
        guard armed, let touch = event.allTouches?.first else { return }
        let p = touch.location(in: view)
        touches.append(DevicePoint(x: p.x/view.bounds.width, y: p.y/view.bounds.height))
        armed = false
    }
    @objc private func interrupted() {
        guard !finished else { return }
        task?.cancel()
    }
    @objc private func closeTapped() {
        task?.cancel()
        Task {
            if !finished { await controller.cancelCalibration() }
            onClose()
        }
    }
    private func requireVisible() throws {
        try Task.checkCancellation()
        guard view.window != nil, UIApplication.shared.applicationState == .active,
              view.bounds == stableBounds, view.window?.windowScene?.effectiveGeometry.interfaceOrientation == stableOrientation else {
            throw DeviceControlError.connection(text("bluetooth.validationInterrupted"))
        }
    }
    private func run() async {
        do {
            try await Task.sleep(for: .milliseconds(500))
            stableBounds = view.bounds
            stableOrientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .unknown
            try requireVisible()
            guard let window = view.window else { throw DeviceControlError.staleFrame }
            try await controller.beginCalibration(window: window, viewport: view)
            try requireVisible()
            // Only this full-screen, harmless target is eligible. No edge search.
            field.isHidden = true; close.isEnabled = true
            for p in [DevicePoint(x: 0.25, y: 0.25), DevicePoint(x: 0.75, y: 0.25), DevicePoint(x: 0.25, y: 0.75), DevicePoint(x: 0.62, y: 0.61)] {
                try requireVisible()
                let count = touches.count
                armed = true
                try await controller.calibrationClick(x: p.x, y: p.y)
                let until = Date().addingTimeInterval(2)
                while touches.count == count && Date() < until {
                    try await Task.sleep(for: .milliseconds(50)); try requireVisible()
                }
                armed = false
                guard touches.count == count + 1 else { throw DeviceControlError.connection(text("bluetooth.validationFailed")) }
                try await Task.sleep(for: .milliseconds(150))
            }
            try controller.completeCalibration(observed: touches)
            field.isHidden = false
            // Clipboard + HID paste is checked through the actual text field.
            field.becomeFirstResponder()
            try await Task.sleep(for: .milliseconds(650))
            let image = try await controller.captureScreenshot()
            let expected = "Eiscue 你好 " + String(Int.random(in: 1000...9999))
            try requireVisible()
            try await controller.pasteCalibrationText(expected, frameID: image.frameID)
            let until = Date().addingTimeInterval(3)
            while field.text != expected && Date() < until {
                try await Task.sleep(for: .milliseconds(50)); try requireVisible()
            }
            guard field.text == expected else { throw DeviceControlError.connection(text("bluetooth.keyboardFailed")) }
            try requireVisible()
            try controller.markKeyboardVerified()
            field.resignFirstResponder()
            finished = true
            status.text = text("bluetooth.validationPassed")
            close.setTitle(text("bluetooth.done"), for: .normal)
            saveReport(passed: true)
        } catch {
            armed = false
            await controller.cancelCalibration()
            status.text = text("bluetooth.validationFailed") + "\n" + error.localizedDescription
            close.setTitle(text("bluetooth.done"), for: .normal)
            saveReport(passed: false)
        }
    }
    private func saveReport(passed: Bool) {
        let report: [String: Any] = ["passed": passed, "timestamp": Date().timeIntervalSince1970,
            "pointCount": touches.count, "points": touches.map { ["x": $0.x, "y": $0.y] },
            "width": view.bounds.width, "height": view.bounds.height, "keyboardVerified": passed]
        let directory = URL.applicationSupportDirectory.appendingPathComponent("EiscueBluetoothSetup")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
            try data.write(to: directory.appendingPathComponent("last-validation.json"), options: [.atomic, .completeFileProtection])
        } catch { /* Diagnostics never change the observed result. */ }
    }
    private func text(_ key: String) -> String { NSLocalizedString(key, tableName: "Bluetooth", comment: "") }
}
