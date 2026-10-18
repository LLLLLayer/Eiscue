import EiscueDeviceCore
import SwiftUI
import UIKit

struct BluetoothBoardSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsValidation = false
    @State private var confirmsUSBPhone = false

    var body: some View {
        VStack(spacing: 12) {
            if model.showsOnboarding, model.boardHardwareStopPending {
                BoardHardwareStopNotice()
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepHeader("1", "bluetooth.connectTitle", complete: model.isBluetoothConnected,
                               stacksActions: model.isConnecting) {
                        connectionActions
                    }
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
                    if model.isBluetoothConnected && model.hasBoardCompanionDisplay {
                        Label(text("bluetooth.companionHint"), systemImage: "display")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("boardCompanionHint")
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepHeader("2", "bluetooth.shareTitle", complete: model.isBluetoothScreenShared) {
                        screenSharingAction
                    }
                    if !model.isBluetoothScreenShared {
                        Text(text("bluetooth.shareDetail")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    stepHeader("3", "bluetooth.verifyTitle", complete: model.isBluetoothPointerVerified) {
                        if model.isBluetoothPointerVerified && (!model.bluetoothController.supportsRelativeDrag || model.bluetoothController.isRelativeDragVerified) {
                            Text(text("bluetooth.validationCompleteTitle"))
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("bluetoothCalibrationComplete")
                        } else {
                            Button(text(model.isBluetoothPointerVerified ? "bluetooth.verifyAgain" : "bluetooth.verifyButton")) {
                                if model.bluetoothInputRoute == .usb { confirmsUSBPhone = true }
                                else { showsValidation = true }
                            }
                            .buttonStyle(.glass).controlSize(.small).frame(minHeight: 44)
                            .disabled(!model.isBluetoothConnected || !model.isBluetoothScreenShared || model.isBoardHardwareStopped || model.isBusy)
                            .accessibilityIdentifier("bluetoothVerifyButton")
                        }
                    }
                    if !model.isBluetoothPointerVerified {
                        Text(text("bluetooth.verifyDetail"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if model.isBluetoothConnected, !model.bluetoothController.supportsRelativeDrag {
                        Text(text("bluetooth.swipeFirmwareUpdate"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.isBluetoothPointerVerified, !model.bluetoothController.isRelativeDragVerified {
                        Text(text("bluetooth.swipeCheckNeeded"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
        .modifier(BluetoothInputCheckPresentation(showsValidation: $showsValidation, confirmsUSBPhone: $confirmsUSBPhone))
    }

    private var connectionActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if model.isBluetoothConnected {
                Button(text("bluetooth.disconnect")) { Task { await model.disconnectDevice() } }
                    .buttonStyle(.glass).frame(minHeight: 44)
                    .accessibilityIdentifier("bluetoothDisconnectButton")
            } else {
                Button { Task { await model.enableDeviceControl() } } label: {
                    HStack(spacing: 8) {
                        if model.isConnecting { ProgressView().tint(EiscueStyle.onAccent) }
                        Text(text(connectionLabel))
                    }
                }
                .buttonStyle(.glassProminent).frame(minHeight: 44)
                .foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy)
                .accessibilityIdentifier("bluetoothConnectButton")
                if model.isConnecting {
                    Button(String(localized: "common.cancel")) { Task { await model.disconnectDevice() } }
                        .buttonStyle(.glass).frame(minHeight: 44)
                }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var screenSharingAction: some View {
        if model.isBluetoothScreenShared {
            Button(text("bluetooth.stopSharing")) {
                Task {
                    if model.isRunning, model.activeRun?.scope != .chat { await model.stop() }
                    guard let lease = try? model.deviceSession.acquire(.setup) else { return }
                    defer { lease.release() }
                    do { try await model.bluetoothController.stopSharing() }
                    catch { model.errorMessage = error.localizedDescription }
                    model.handleBluetoothSessionChange()
                    await model.refreshDeviceStatus()
                }
            }
            .buttonStyle(.glass).controlSize(.small).frame(minHeight: 44)
        } else {
            ScreenBroadcastPicker().frame(width: 52, height: 52)
                .disabled(model.deviceSession.isBusy)
                .accessibilityLabel(text("bluetooth.shareButtonHint"))
                .accessibilityIdentifier("bluetoothScreenShareButton")
        }
    }

    private func stepHeader<Actions: View>(_ number: String, _ key: String, complete: Bool,
                                          stacksActions: Bool = false, @ViewBuilder actions: () -> Actions) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize || stacksActions
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            step(number, key, complete: complete)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions().fixedSize(horizontal: !stacked, vertical: true)
        }
        .frame(minHeight: 52, alignment: .leading)
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
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bluetoothSetupStep\(number)")
        }.foregroundStyle(.primary)
    }
    private func text(_ key: String) -> String { NSLocalizedString(key, tableName: "Bluetooth", comment: "") }
}

struct BluetoothInputCheckPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var showsValidation: Bool
    @Binding var confirmsUSBPhone: Bool

    func body(content: Content) -> some View {
        content
            .alert(String(localized: "bluetooth.usbConfirmTitle", table: "Bluetooth"), isPresented: $confirmsUSBPhone) {
                Button(String(localized: "bluetooth.usbConfirmButton", table: "Bluetooth")) { showsValidation = true }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            } message: { Text(String(localized: "bluetooth.usbConfirmDetail", table: "Bluetooth")) }
            .fullScreenCover(isPresented: $showsValidation, onDismiss: {
                Task { await model.refreshDeviceStatus(); model.bluetoothRevision += 1 }
            }) {
                BluetoothPointerValidation(model: model) { showsValidation = false }
                    .ignoresSafeArea().interactiveDismissDisabled()
            }
    }
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

@MainActor
final class BluetoothCalibrationOwnership {
    let lease: DeviceLease
    private var cleanupTask: Task<Void, Never>?
    private var calibrationStarted = false

    init(session: DeviceSession) throws {
        lease = try session.acquire(.setup)
        lease.client.device.invalidate()
    }
    func beginCalibration(_ begin: @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard cleanupTask == nil else { throw CancellationError() }
        // Begin may clear the previous mapping before suspending or failing.
        calibrationStarted = true
        try await begin()
    }
    func cancelCalibration(_ cancel: @MainActor () async -> Void) async {
        guard calibrationStarted else { return }
        calibrationStarted = false
        await cancel()
    }
    func finish(after operation: Task<Void, Never>?, cleanup: @escaping @MainActor () async -> Void) async {
        if cleanupTask == nil {
            let lease = lease
            cleanupTask = Task {
                await operation?.value
                await cleanup()
                calibrationStarted = false
                lease.release()
            }
        }
        await cleanupTask?.value
    }
}

private struct BluetoothPointerValidation: UIViewControllerRepresentable {
    let model: AppModel
    let onClose: () -> Void
    func makeUIViewController(context: Context) -> BluetoothPointerValidationController {
        BluetoothPointerValidationController(model: model, onClose: onClose)
    }
    func updateUIViewController(_ uiViewController: BluetoothPointerValidationController, context: Context) {
        uiViewController.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        uiViewController.view.tintColor = .label
    }
    static func dismantleUIViewController(_ controller: BluetoothPointerValidationController, coordinator: ()) {
        controller.finishPresentation(close: false)
    }
}

@MainActor
private final class BluetoothPointerValidationController: UIViewController {
    private let controller: BluetoothDeviceController
    private let onClose: () -> Void
    private let onCleanupError: (Error) -> Void
    private let ownership: BluetoothCalibrationOwnership?
    private let acquisitionFailure: Error?
    private let target = BluetoothCalibrationTarget(type: .custom)
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
    private var relativeTrace: BluetoothCalibrationContactTrace?
    private var relativeObservations: [BluetoothRelativeCalibrationObservation] = []
    private var relativeCheckPassed = false
    private var armed = false
    private var stableBounds = CGRect.zero
    private var stableOrientation = UIInterfaceOrientation.unknown
    private var finished = false
    private var failed = false
    private var ending = false

    init(model: AppModel, onClose: @escaping () -> Void) {
        controller = model.bluetoothController; self.onClose = onClose
        onCleanupError = { [weak model] in model?.errorMessage = $0.localizedDescription }
        do {
            guard model.deviceConnectionMethod == .bluetoothBoard, model.isBluetoothConnected,
                  model.isBluetoothScreenShared, !model.isBusy else { throw DeviceControlError.busy }
            ownership = try BluetoothCalibrationOwnership(session: model.deviceSession)
            acquisitionFailure = nil
        } catch { ownership = nil; acquisitionFailure = error }
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        target.backgroundColor = .systemBackground
        target.isMultipleTouchEnabled = true
        target.addTarget(self, action: #selector(observedTouch(_:event:)), for: .touchUpInside)
        target.onContact = { [weak self] id, phase, location, uptime in
            guard let self, view.bounds.width > 0, view.bounds.height > 0 else { return }
            relativeTrace?.record(id: id, phase: phase,
                point: DevicePoint(x: location.x / view.bounds.width, y: location.y / view.bounds.height), uptime: uptime)
        }
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
        guard task == nil, !ending else { return }
        task = Task { [weak self] in await self?.run() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finishPresentation(close: false)
    }
    @objc private func observedTouch(_ button: UIButton, event: UIEvent) {
        guard armed, let touch = event.allTouches?.first else { return }
        let p = touch.location(in: view)
        touches.append(DevicePoint(x: p.x/view.bounds.width, y: p.y/view.bounds.height))
        armed = false
    }
    @objc private func interrupted() {
        finishPresentation(close: true)
    }
    @objc private func closeTapped() {
        finishPresentation(close: true)
    }
    func finishPresentation(close shouldClose: Bool) {
        ending = true
        task?.cancel()
        Task {
            await ownership?.finish(after: task) { [self] in
                if finished {
                    do { try await ownership?.lease.client.finishTask() }
                    catch { onCleanupError(error) }
                }
                else { await cancelCalibration() }
                field.resignFirstResponder()
            }
            if shouldClose { onClose() }
        }
    }
    private func cancelCalibration() async {
        await ownership?.cancelCalibration { await controller.cancelCalibration() }
    }
    private func requireVisible() throws {
        try Task.checkCancellation()
        guard !ending, view.window != nil, UIApplication.shared.applicationState == .active,
              view.bounds == stableBounds, view.window?.windowScene?.effectiveGeometry.interfaceOrientation == stableOrientation else {
            throw DeviceControlError.connection(text("bluetooth.validationInterrupted"))
        }
    }
    private func run() async {
        do {
            if let acquisitionFailure { throw acquisitionFailure }
            guard let ownership else { throw DeviceControlError.busy }
            try await Task.sleep(for: .milliseconds(500))
            stableBounds = view.bounds
            stableOrientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .unknown
            try requireVisible()
            guard let window = view.window else { throw DeviceControlError.staleFrame }
            try await ownership.beginCalibration { try await controller.beginCalibration(window: window, viewport: view) }
            try requireVisible()
            // Only this full-screen, harmless target is eligible. No edge search.
            field.isHidden = true; close.isEnabled = true
            let checkCount = controller.supportsRelativeDrag ? 11 : 5
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
                progress.setProgress(Float(touches.count) / Float(checkCount), animated: true)
                try await Task.sleep(for: .milliseconds(150))
            }
            try await controller.completeCalibration(observed: touches)
            if controller.supportsRelativeDrag {
                heading.text = text("bluetooth.validationSwipeTitle")
                status.text = text("bluetooth.checkingSwipe")
                symbol.image = UIImage(systemName: "hand.draw")
                view.setNeedsLayout()
                relativeCheckPassed = try await checkRelativeInput(checkCount: checkCount)
            }
            heading.text = text("bluetooth.validationInputTitle")
            status.text = text("bluetooth.verifying")
            symbol.image = UIImage(systemName: "keyboard")
            view.setNeedsLayout()
            field.isHidden = false
            // Clipboard + HID paste is checked through the actual text field.
            field.becomeFirstResponder()
            try await Task.sleep(for: .milliseconds(650))
            let image = try await controller.capture()
            let expected = "Eiscue 你好 " + String(Int.random(in: 1000...9999))
            try requireVisible()
            try await controller.pasteCalibrationText(expected, frameID: image.frameID)
            let until = Date().addingTimeInterval(3)
            while field.text != expected && Date() < until {
                try await Task.sleep(for: .milliseconds(50)); try requireVisible()
            }
            guard field.text == expected else { throw DeviceControlError.connection(text("bluetooth.keyboardFailed")) }
            try requireVisible()
            try await controller.markKeyboardVerified()
            field.resignFirstResponder()
            finished = true
            heading.text = text("bluetooth.validationCompleteTitle")
            symbol.image = UIImage(systemName: "checkmark")
            progress.setProgress(1, animated: true)
            status.text = text(controller.supportsRelativeDrag && !relativeCheckPassed
                               ? "bluetooth.swipeCheckNeeded" : "bluetooth.validationPassed")
            close.setTitle(text("bluetooth.done"), for: .normal)
            saveReport(passed: true)
            view.setNeedsLayout()
        } catch {
            armed = false; relativeTrace = nil
            await cancelCalibration()
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
    private func checkRelativeInput(checkCount: Int) async throws -> Bool {
        guard controller.isRelativeDragReady else { return false }
        defer { relativeTrace = nil }
        for probe in BluetoothRelativeCalibrationProbe.allCases {
            try requireVisible()
            relativeTrace = BluetoothCalibrationContactTrace()
            let receipt = try await controller.runRelativeCalibrationProbe(probe)
            let until = Date().addingTimeInterval(2)
            while relativeTrace?.hasTerminated != true && Date() < until {
                try await Task.sleep(for: .milliseconds(50)); try requireVisible()
            }
            // A completed command without the expected UIKit contact cannot
            // enable swipe, but doesn't invalidate the verified tap mapping.
            guard let observation = relativeTrace?.observation(probe: probe, receipt: receipt) else { return false }
            relativeTrace = nil
            relativeObservations.append(observation)
            progress.setProgress(Float(4 + relativeObservations.count) / Float(checkCount), animated: true)
            try await Task.sleep(for: .milliseconds(150))
        }
        do { try await controller.completeRelativeCalibration(observed: relativeObservations) }
        catch DeviceControlError.invalidCoordinates { return false }
        return true
    }
    private func saveReport(passed: Bool) {
        guard ownership != nil else { return }
        let report: [String: Any] = ["passed": passed, "timestamp": Date().timeIntervalSince1970,
            "pointCount": touches.count, "points": touches.map { ["x": $0.x, "y": $0.y] },
            "width": view.bounds.width, "height": view.bounds.height, "keyboardVerified": passed,
            "relativeDragSupported": controller.supportsRelativeDrag,
            "relativeDragVerified": controller.isRelativeDragVerified,
            "relativeProbes": relativeObservations.map { ["probe": $0.probe.rawValue,
                "contacts": $0.contactCount, "movedEvents": $0.movedEventCount,
                "endedNormally": $0.endedNormally, "start": ["x": $0.start.x, "y": $0.start.y],
                "end": ["x": $0.end.x, "y": $0.end.y],
                "contactDuration": $0.endedUptime - $0.startedUptime] as [String: Any] },
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

/// Tracks UIKit's real contact, independently of the HID command acknowledgement.
struct BluetoothCalibrationContactTrace {
    private var contacts = Set<Int>()
    private var primary: Int?
    private var start: DevicePoint?
    private var end: DevicePoint?
    private var startedUptime: TimeInterval?
    private var endedUptime: TimeInterval?
    private var movedEvents = 0
    private var endedNormally = false
    private(set) var hasTerminated = false

    mutating func record(id: Int, phase: UITouch.Phase, point: DevicePoint, uptime: TimeInterval) {
        contacts.insert(id)
        if phase == .began, primary == nil { primary = id; start = point; startedUptime = uptime }
        guard primary == id, !hasTerminated else { return }
        end = point
        switch phase {
        case .moved: movedEvents += 1
        case .ended: hasTerminated = true; endedNormally = true; endedUptime = uptime
        case .cancelled: hasTerminated = true; endedUptime = uptime
        default: break
        }
    }
    func observation(probe: BluetoothRelativeCalibrationProbe, receipt: UUID) -> BluetoothRelativeCalibrationObservation? {
        guard hasTerminated, let start, let end, let startedUptime, let endedUptime else { return nil }
        return .init(probe: probe, receiptToken: receipt, start: start, end: end,
                     contactCount: contacts.count, movedEventCount: movedEvents, endedNormally: endedNormally,
                     startedUptime: startedUptime, endedUptime: endedUptime)
    }
}

@MainActor private final class BluetoothCalibrationTarget: UIButton {
    var onContact: ((Int, UITouch.Phase, CGPoint, TimeInterval) -> Void)?
    private var contactIDs: [ObjectIdentifier: Int] = [:]
    private var nextContactID = 0

    private func observe(_ touches: Set<UITouch>) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if contactIDs[key] == nil { nextContactID += 1; contactIDs[key] = nextContactID }
            onContact?(contactIDs[key]!, touch.phase, touch.location(in: self), touch.timestamp)
            if touch.phase == .ended || touch.phase == .cancelled { contactIDs[key] = nil }
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        observe(touches); super.touchesBegan(touches, with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        observe(touches); super.touchesMoved(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        observe(touches); super.touchesEnded(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        observe(touches); super.touchesCancelled(touches, with: event)
    }
}
