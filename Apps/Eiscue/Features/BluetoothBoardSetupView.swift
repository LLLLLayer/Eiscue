import EiscueDeviceKit
import SwiftUI
import UIKit

struct BluetoothBoardSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showsValidation = false
    @State private var confirmsUSBPhone = false

    var body: some View {
        VStack(spacing: 12) {
            if model.showsOnboarding, model.boardHardwareStopPending {
                BoardHardwareStopNotice()
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    step("1", "bluetooth.connectTitle", complete: model.isBluetoothConnected)
                    Picker(text("bluetooth.inputRoute"), selection: Binding(
                        get: { model.bluetoothInputRoute },
                        set: { route in Task { await model.selectBluetoothInputRoute(route) } }
                    )) {
                        Text(text("bluetooth.inputBluetooth")).tag(BluetoothBoardInputRoute.bluetooth)
                        Text(text("bluetooth.inputUSB")).tag(BluetoothBoardInputRoute.usb)
                    }
                    .pickerStyle(.segmented).disabled(model.isBusy)
                    .accessibilityIdentifier("bluetoothInputRoutePicker")
                    if !model.isBluetoothConnected {
                        Text(text(model.bluetoothInputRoute == .usb ? "bluetooth.usbPowerDetail" : "bluetooth.powerDetail"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(text("bluetooth.assistiveTouch")).font(.caption).foregroundStyle(.secondary)
                        Text(text("bluetooth.firstS3Connection")).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isBluetoothConnected {
                        if model.hasBoardCompanionDisplay {
                            Label(text("bluetooth.companionHint"), systemImage: "display")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("boardCompanionHint")
                        }
                        Button(text("bluetooth.disconnect")) { Task { await model.disconnectDevice() } }
                            .buttonStyle(.glass).accessibilityIdentifier("bluetoothDisconnectButton")
                    } else {
                        Button { Task { await model.enableDeviceControl() } } label: {
                            HStack {
                                if model.isConnecting { ProgressView().tint(EiscueStyle.onAccent) }
                                Text(text(connectionLabel))
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .foregroundStyle(EiscueStyle.onAccent)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("bluetoothConnectButton")
                        if model.isConnecting {
                            Button(String(localized: "common.cancel")) { Task { await model.disconnectDevice() } }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
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
                VStack(alignment: .leading, spacing: 12) {
                    step("3", "bluetooth.verifyTitle", complete: model.isBluetoothPointerVerified)
                    Text(text(model.isBluetoothPointerVerified ? "bluetooth.readyDetail" : "bluetooth.verifyDetail"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button(text(model.isBluetoothPointerVerified ? "bluetooth.verifyAgain" : "bluetooth.verifyButton")) {
                        if model.bluetoothInputRoute == .usb { confirmsUSBPhone = true }
                        else { showsValidation = true }
                    }
                        .buttonStyle(.glass)
                        .disabled(!model.isBluetoothConnected || !model.isBluetoothScreenShared || model.isBoardHardwareStopped || model.isBusy)
                        .accessibilityIdentifier("bluetoothVerifyButton")
                }
            }
            if let error = model.deviceConnectionError,
               !model.boardHardwareStopPending || error != text("bluetooth.hardwareStopped") {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.primary)
                    .accessibilityIdentifier("bluetoothConnectionError")
            } else if !model.boardHardwareStopPending, model.isBluetoothConnected, !model.bluetoothController.isInputReady,
                      case .unavailable(let reason) = model.deviceStatus {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("bluetoothReadinessHint")
            }
        }
        .alert(text("bluetooth.usbConfirmTitle"), isPresented: $confirmsUSBPhone) {
            Button(text("bluetooth.usbConfirmButton")) { showsValidation = true }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: { Text(text("bluetooth.usbConfirmDetail")) }
        .fullScreenCover(isPresented: $showsValidation, onDismiss: {
            Task { await model.refreshDeviceStatus(); model.bluetoothRevision += 1 }
        }) {
            BluetoothPointerValidation(controller: model.bluetoothController) { showsValidation = false }
                .ignoresSafeArea().interactiveDismissDisabled()
        }
    }

    private var connectionLabel: String {
        guard model.isConnecting else { return "bluetooth.connectButton" }
        if model.bluetoothInputRoute == .usb, model.bluetoothController.board.state == .ready {
            return "bluetooth.waitingForUSB"
        }
        return "bluetooth.connecting"
    }

    private func step(_ number: String, _ key: String, complete: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.08))
                if complete { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                else { Text(number).font(.caption.weight(.semibold).monospacedDigit()) }
            }.frame(width: 28, height: 28).accessibilityHidden(true)
            Text(text(key)).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }.foregroundStyle(.primary)
    }
    private func text(_ key: String) -> String { NSLocalizedString(key, tableName: "Bluetooth", comment: "") }
}

struct BoardHardwareStopNotice: View {
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "stop.circle.fill").accessibilityHidden(true)
                    Text(String(localized: "bluetooth.hardwareStoppedTitle", table: "Bluetooth"))
                        .accessibilityIdentifier("boardHardwareStopTitle")
                }.font(.headline)
                Text(String(localized: "bluetooth.hardwareStopped", table: "Bluetooth"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BluetoothPointerValidation: UIViewControllerRepresentable {
    let controller: BluetoothDeviceController
    let onClose: () -> Void
    func makeUIViewController(context: Context) -> BluetoothPointerValidationController {
        BluetoothPointerValidationController(controller: controller, onClose: onClose)
    }
    func updateUIViewController(_ uiViewController: BluetoothPointerValidationController, context: Context) {
        uiViewController.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        uiViewController.view.tintColor = .label
    }
}

@MainActor
private final class BluetoothPointerValidationController: UIViewController {
    private let controller: BluetoothDeviceController
    private let onClose: () -> Void
    private let target = UIButton(type: .custom)
    private let symbol = UIImageView()
    private let heading = UILabel()
    private let status = UILabel()
    private let statusScroll = UIScrollView()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let close = UIButton(type: .system)
    private let field = UITextField()
    private var task: Task<Void, Never>?
    private enum ValidationFailure: Error { case touchMissing }
    private var touches: [DevicePoint] = []
    private var armed = false
    private var stableBounds = CGRect.zero
    private var stableOrientation = UIInterfaceOrientation.unknown
    private var finished = false
    private var failed = false

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
        symbol.image = UIImage(systemName: "hand.tap")
        symbol.preferredSymbolConfiguration = .init(pointSize: 32, weight: .regular)
        symbol.contentMode = .center; symbol.tintColor = .label
        symbol.backgroundColor = .secondarySystemBackground
        symbol.layer.cornerRadius = 20
        symbol.isAccessibilityElement = false
        view.addSubview(symbol)
        heading.text = text("bluetooth.validationTouchTitle")
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.adjustsFontForContentSizeCategory = true
        heading.textAlignment = .center; heading.numberOfLines = 0
        heading.accessibilityTraits = .header
        view.addSubview(heading)
        status.accessibilityIdentifier = "bluetoothValidationStatus"
        close.accessibilityIdentifier = "bluetoothValidationCloseButton"
        status.text = text("bluetooth.verifying")
        status.numberOfLines = 0; status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel
        status.isUserInteractionEnabled = false
        statusScroll.isUserInteractionEnabled = false
        statusScroll.addSubview(status)
        view.addSubview(statusScroll)
        progress.progressTintColor = .label; progress.trackTintColor = .tertiarySystemFill
        progress.isUserInteractionEnabled = false
        progress.accessibilityLabel = text("bluetooth.validationProgress")
        view.addSubview(progress)
        field.backgroundColor = .secondarySystemBackground
        field.layer.cornerRadius = 16; field.textAlignment = .center
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = text("bluetooth.keyboardCheck")
        field.isHidden = true
        field.inputView = UIView(frame: .zero)
        field.inputAssistantItem.leadingBarButtonGroups = []; field.inputAssistantItem.trailingBarButtonGroups = []
        view.addSubview(field)
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        configuration.buttonSize = .large
        close.configuration = configuration
        close.setTitle(text("bluetooth.cancel"), for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(close)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        target.frame = view.bounds
        let width = min(500, view.bounds.width - 48), x = (view.bounds.width - width) / 2
        let compact = view.bounds.height < 650
        let top = view.safeAreaInsets.top + (compact ? 8 : 36)
        let closeHeight = max(48, close.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        // In landscape a large bottom button can cover the lower-left
        // calibration point. Keep the exit in the lower-right corner instead.
        let closeWidth = compact ? min(width, view.bounds.width * 0.22) : width
        let closeX = compact ? view.bounds.width - view.safeAreaInsets.right - 16 - closeWidth : x
        close.frame = CGRect(x: closeX, y: view.bounds.height - view.safeAreaInsets.bottom - 14 - closeHeight,
                             width: closeWidth, height: closeHeight)
        let fieldHeight = max(52, (field.font?.lineHeight ?? 28) + 24)
        let fieldY = min(view.bounds.height * 0.52, close.frame.minY - 16 - fieldHeight)
        field.frame = CGRect(x: x, y: fieldY, width: width, height: fieldHeight)
        let statusBottom = failed ? close.frame.minY - 20 : fieldY - 48
        let naturalHeadingHeight = heading.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let showsSymbol = !compact && statusBottom - top >= 96 + naturalHeadingHeight + 64
        symbol.isHidden = !showsSymbol
        symbol.frame = CGRect(x: view.bounds.midX - 36, y: top, width: 72, height: 72)
        let headingY = showsSymbol ? symbol.frame.maxY + 24 : top
        let headingHeight = min(naturalHeadingHeight, max(28, statusBottom - headingY - 54))
        heading.frame = CGRect(x: x, y: headingY, width: width, height: headingHeight)
        let statusY = heading.frame.maxY + 10
        let naturalStatusHeight = status.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        statusScroll.frame = CGRect(x: x, y: statusY, width: width,
                                    height: min(max(0, statusBottom - statusY), naturalStatusHeight))
        status.frame = CGRect(x: 0, y: 0, width: width, height: naturalStatusHeight)
        statusScroll.contentSize = status.bounds.size
        progress.frame = CGRect(x: x + 32, y: statusScroll.frame.maxY + 20, width: width - 64, height: 4)
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
                guard touches.count == count + 1 else { throw ValidationFailure.touchMissing }
                progress.setProgress(Float(touches.count) / 5, animated: true)
                try await Task.sleep(for: .milliseconds(150))
            }
            try controller.completeCalibration(observed: touches)
            heading.text = text("bluetooth.validationInputTitle")
            symbol.image = UIImage(systemName: "keyboard")
            view.setNeedsLayout()
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
            heading.text = text("bluetooth.validationCompleteTitle")
            symbol.image = UIImage(systemName: "checkmark")
            progress.setProgress(1, animated: true)
            status.text = text("bluetooth.validationPassed")
            close.setTitle(text("bluetooth.done"), for: .normal)
            saveReport(passed: true)
            view.setNeedsLayout()
        } catch {
            armed = false
            await controller.cancelCalibration()
            field.resignFirstResponder()
            failed = true; field.isHidden = true; progress.isHidden = true
            statusScroll.isUserInteractionEnabled = true
            heading.text = text("bluetooth.validationFailedTitle")
            symbol.image = UIImage(systemName: "exclamationmark")
            status.font = .preferredFont(forTextStyle: .body)
            if error is ValidationFailure {
                status.text = text(controller.inputRoute == .usb ? "bluetooth.usbTouchMissing" : "bluetooth.validationFailed")
            } else { status.text = text("bluetooth.validationFailed") + "\n" + error.localizedDescription }
            close.setTitle(text("bluetooth.done"), for: .normal)
            saveReport(passed: false)
            view.setNeedsLayout()
        }
    }
    private func saveReport(passed: Bool) {
        let report: [String: Any] = ["passed": passed, "timestamp": Date().timeIntervalSince1970,
            "pointCount": touches.count, "points": touches.map { ["x": $0.x, "y": $0.y] },
            "width": view.bounds.width, "height": view.bounds.height, "keyboardVerified": passed,
            "inputRoute": controller.inputRoute.rawValue, "isS3": controller.outputInfo?.isS3 == true,
            "authenticated": controller.board.usesAuthenticatedCommands]
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
