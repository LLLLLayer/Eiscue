import EiscueDeviceKit
import SwiftUI
import UniformTypeIdentifiers

struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasRequestedConnection = false
    @State private var importsIdentity = false
    #if DEBUG
    @State private var showsProbe = false
    @State private var previewImage: UIImage?
    @State private var showsPreview = false
    @State private var showsBluetoothValidation = false
    @State private var confirmsUSBPhone = false
    #endif

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(title: text("device.section.usage")) {
                        SurfaceCard { deviceControlPermission }
                    }
                    deviceHeader
                    connectionSettings
                    if model.deviceConnectionMethod == .bluetoothBoard { BluetoothBoardSetupView() }
                    else { connectionCard }
                    #if DEBUG
                    if model.showsDebugTools && model.isDeviceReady { debugSection }
                    #endif
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .background(EiscueStyle.background)
            .navigationTitle("common.device")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("devicePage")
            .task(id: shouldRefreshPairingTransfer) {
                guard shouldRefreshPairingTransfer else { return }
                while !Task.isCancelled {
                    model.refreshPairingTransfer()
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { return }
                }
            }
            .onChange(of: model.deviceConnectionMethod) { _, _ in
                hasRequestedConnection = false
            }
            .onChange(of: model.deviceControlBackend) { _, _ in hasRequestedConnection = false }
            .onChange(of: model.isDeviceReady) { _, ready in
                if ready { hasRequestedConnection = false }
            }
            .fileImporter(isPresented: $importsIdentity, allowedContentTypes: [.json, .data]) { result in
                if case .success(let url) = result { Task { await model.importPairingIdentity(url) } }
                if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
            }
            #if DEBUG
            .sheet(isPresented: $showsProbe) { ControlProbeView() }
            .sheet(isPresented: $showsPreview) {
                if let previewImage { DeviceScreenPreview(image: previewImage) }
            }
            .modifier(BluetoothInputCheckPresentation(showsValidation: $showsBluetoothValidation, confirmsUSBPhone: $confirmsUSBPhone))
            #endif
        }
    }

    private var deviceControlPermission: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.allowsDeviceControl }, set: { model.allowsDeviceControl = $0 })) {
                Text(String(localized: "device.aiControl.title", table: "Connections"))
                    .font(.subheadline.weight(.medium))
            }
            .tint(EiscueStyle.switchTint)
            .disabled(!model.canChangeDeviceControl)
            .accessibilityIdentifier("deviceControlToggle")
            Text(String(localized: "device.aiControl.detail", table: "Connections"))
                .font(.caption).foregroundStyle(.secondary)
            if !model.canChangeDeviceControl && (model.isRunning || model.needsRecovery || model.pausedRun != nil) {
                Text(String(localized: "device.aiControl.finishTask", table: "Connections"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            EiscueHeadView(state: model.isDeviceReady ? .awake : (isConnecting ? .looking : .asleep))
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.device.name).font(.headline)
                Text("\(model.device.platform == .iPadOS ? "iPadOS" : "iOS") \(model.device.systemVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.deviceConnectionMethod == .bluetoothBoard {
                    Text(bluetoothStatusTitle)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var bluetoothStatusTitle: String {
        if model.isBoardHardwareStopped { return String(localized: "bluetooth.hardwareStoppedTitle", table: "Bluetooth") }
        if isConnecting { return String(localized: "device.connecting") }
        if model.isDeviceReady { return String(localized: "device.controlReady") }
        if model.deviceConnectionError != nil { return text("device.status.failed") }
        return text(model.isBluetoothConnected ? "device.status.finishSetup" : "device.status.disconnected")
    }

    private var connectionStatusSymbol: String {
        switch model.connectionIndicator {
        case .ready: "checkmark.circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.circle"
        case .paired: "minus.circle"
        case .unpaired: "circle.dotted"
        }
    }

    private var shouldRefreshPairingTransfer: Bool {
        scenePhase == .active && !model.hasPairingIdentity && model.deviceConnectionMethod != .bluetoothBoard
    }

    private var isConnecting: Bool { model.isConnecting || model.isPairing || model.isManagingTunnel }
    private var usesSystemPairing: Bool { model.deviceConnectionMethod == .localVPN && model.supportsSystemPairing }

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Connections")
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var connectionSettings: some View {
        section(title: text("device.section.connection")) {
            VStack(spacing: 0) {
                DeviceConnectionMethodPicker(embedded: true)
                if model.deviceConnectionMethod != .bluetoothBoard {
                    Divider().padding(.horizontal, 16)
                    DeviceControlBackendPicker(embedded: true)
                }
            }
            .background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var connectionTitle: String {
        if isConnecting { return String(localized: model.isPairing ? "device.pairing" : "device.connecting") }
        if model.isDeviceReady { return String(localized: "device.controlReady") }
        if model.deviceConnectionError != nil || (model.deviceConnectionMethod == .localVPN && model.localTunnel.lastError != nil) {
            return text("device.status.failed")
        }
        return text(model.hasPairingIdentity ? "device.status.disconnected" : "device.pairing.required")
    }

    private var connectionCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            if isConnecting { ProgressView().controlSize(.small) }
                            else { Image(systemName: connectionStatusSymbol).accessibilityHidden(true) }
                            Text(connectionTitle)
                                .accessibilityIdentifier(model.hasPairingIdentity ? "devicePairingComplete" : "deviceConnectionStatus")
                        }
                        .font(.subheadline.weight(.semibold))
                        if model.deviceConnectionMethod == .localVPN { vpnUsage }
                        else {
                            Text(text("device.connection.usbStatusDetail"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    primaryConnectionAction
                        .controlSize(.small).frame(minHeight: 44)
                        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                }
                if let code = model.pairingCode {
                    Text(code).font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .textSelection(.enabled).accessibilityIdentifier("pairingCode")
                }
                if showsConnectionMessage { connectionMessage }
                if !isConnecting && !model.isDeviceReady && model.deviceConnectionMethod == .localVPN
                    && (model.localTunnel.isConnected || model.localTunnel.isTransitioning) {
                    disconnectButton
                }
                if !model.hasPairingIdentity {
                    Divider()
                    pairingSetup
                }
            }
        }
    }

    private var vpnUsage: some View {
        Text(String(localized: "device.connection.vpnUsage", table: "Connections"))
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("deviceVPNUsage")
    }

    @ViewBuilder private var primaryConnectionAction: some View {
        if isConnecting || model.isDeviceReady {
            disconnectButton
        } else if model.hasPairingIdentity {
            Button(model.deviceConnectionError == nil ? String(localized: "device.enableControl") : String(localized: "device.retryControl")) {
                hasRequestedConnection = true
                Task { await model.enableDeviceControl() }
            }
            .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
            .disabled(model.isBusy).accessibilityIdentifier("connectDeviceButton")
        } else if usesSystemPairing {
            Button("device.startPairing") {
                hasRequestedConnection = true
                Task {
                    if !model.localTunnel.isConnected { await model.startLocalTunnel() }
                    if model.localTunnel.isConnected { model.startPairing() }
                }
            }
            .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
            .disabled(model.isBusy).accessibilityIdentifier("startPairingButton")
        }
    }

    private var pairingSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            if usesSystemPairing {
                if !isConnecting {
                    Text(String(localized: "setup.inlineSystemPreparation", table: "Onboarding"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(String(localized: "setup.systemPairingDetail", table: "Onboarding"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ComputerPairingHelpView()
                PairingSetupStepTitle(number: 4, title: String(localized: "setup.stepImportTitle", table: "Onboarding"))
                Text(String(localized: model.hasTransferredPairingIdentity ? "setup.inlineTransferReady" : "setup.stepImportWaiting", table: "Onboarding"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.hasTransferredPairingIdentity {
                Button("device.importTransferredPairing") {
                    Task { await model.importTransferredPairingIdentity() }
                }
                .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy).accessibilityIdentifier("importTransferredPairingButton")
            }
            Button(String(localized: "setup.chooseExistingFile", table: "Onboarding")) { importsIdentity = true }
                .buttonStyle(.glass).disabled(model.isBusy)
                .accessibilityIdentifier("importPairingIdentityButton")
            if !usesSystemPairing {
                PairingSetupStepTitle(number: 5, title: String(localized: "setup.stepConnectTitle", table: "Onboarding"))
                Text(String(localized: "setup.stepConnectAfterImport", table: "Onboarding"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            routeRequirements
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disconnectButton: some View {
        Button(isConnecting ? String(localized: "common.cancel") : String(localized: "device.connection.disconnect", table: "Connections")) {
            hasRequestedConnection = false
            Task {
                if model.deviceConnectionMethod == .localVPN { await model.stopLocalTunnel() }
                else { await model.disconnectDevice() }
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 44)
        .disabled(model.isStoppingTunnel || model.isStopping)
        .accessibilityIdentifier("disconnectDeviceButton")
    }

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "device.debug.title", table: "Connections"))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("deviceDebugSectionTitle")
            screenPreview
            SurfaceCard {
                if model.deviceConnectionMethod == .bluetoothBoard {
                    Button {
                        if model.bluetoothInputRoute == .usb { confirmsUSBPhone = true }
                        else { showsBluetoothValidation = true }
                    } label: {
                        connectionSupportLabel(String(localized: "device.openProbe"), symbol: "hand.tap")
                    }
                    .buttonStyle(.plain).disabled(model.isBusy || model.isBoardHardwareStopped)
                    .accessibilityIdentifier("bluetoothVerifyButton")
                } else {
                    Button { showsProbe = true } label: {
                        connectionSupportLabel(String(localized: "device.openProbe"), symbol: "hand.tap")
                    }
                    .buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityIdentifier("deviceProbeButton")
                }
            }
        }
    }

    private func connectionSupportLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24)
            Text(title).font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 32).contentShape(Rectangle())
    }
    #endif

    @ViewBuilder private var routeRequirements: some View {
        if model.deviceConnectionMethod == .usbBoard {
            Text("device.boardConnectionDetail")
                .font(.caption).foregroundStyle(.secondary)
            Text("device.boardHardwareRequirement")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("boardHardwareRequirement")
        }
    }

    private var showsConnectionMessage: Bool {
        isConnecting || model.deviceConnectionError != nil
            || (hasRequestedConnection && !model.isDeviceReady)
            || (model.deviceConnectionMethod == .localVPN && model.localTunnel.lastError != nil)
    }

    private var connectionMessage: some View {
        Text(model.deviceConnectionError
             ?? (model.deviceConnectionMethod == .localVPN ? model.localTunnel.lastError : nil)
             ?? model.connectionMessage)
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("deviceConnectionMessage")
    }

    #if DEBUG
    private var screenPreview: some View {
        Button {
            Task {
                let previousFrameID = model.screenshot?.frameID
                await model.previewScreenshot()
                if let frame = model.screenshot, frame.frameID != previousFrameID, let image = UIImage(data: frame.data) {
                    previewImage = image
                    showsPreview = true
                }
            }
        } label: {
            SurfaceCard {
                HStack(spacing: 12) {
                    Image(systemName: "photo")
                    Text("device.captureScreenshot").font(.subheadline.weight(.medium))
                    Spacer()
                    if model.isConnecting { ProgressView() }
                    else { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                }
                .frame(minHeight: 24)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityIdentifier("deviceScreenPreviewButton")
    }
    #endif
}

#if DEBUG
private struct DeviceScreenPreview: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        NavigationStack {
            ZoomableToolImage(image: image)
                .background(.black)
                .accessibilityIdentifier("deviceScreenPreviewImage")
                .accessibilityLabel(Text("device.captureScreenshot"))
                .navigationTitle("device.captureScreenshot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") { dismiss() }.accessibilityIdentifier("closeDeviceScreenPreviewButton")
                    }
                }
        }
    }
}
#endif

private struct DeviceSettingsRow<Content: View>: View {
    let embedded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if embedded {
            content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SurfaceCard { content }
        }
    }
}

struct DeviceConnectionMethodPicker: View {
    var embedded = false
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsMethods = false
    @State private var pendingMethod: DeviceConnectionMethod?

    private let methods: [DeviceConnectionMethod] = [.localVPN, .bluetoothBoard, .usbBoard]
    private var canChange: Bool {
        !model.isChangingDeviceConnectionMethod && !model.isSaving && !model.isStopping
            && !model.isManagingTunnel && !model.isStoppingTunnel && !model.isImportingAttachments
    }

    var body: some View {
        picker
        .sheet(isPresented: $showsMethods, onDismiss: {
            guard let method = pendingMethod else { return }
            pendingMethod = nil
            Task { await model.selectDeviceConnectionMethod(method) }
        }) {
            DeviceSelectionSheet(title: String(localized: "device.connectionMethod")) {
                ForEach(methods, id: \.self) { method in
                    Button {
                        pendingMethod = method == model.deviceConnectionMethod ? nil : method
                        showsMethods = false
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: method.selectionSymbol).font(.system(size: 22)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(method.selectionTitle).font(.body.weight(.medium))
                                Text(method.selectionDetail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if model.deviceConnectionMethod == method {
                                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(.primary).padding(16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!canChange)
                    .accessibilityLabel(method.selectionTitle).accessibilityHint(method.selectionDetail)
                    .accessibilityValue(model.deviceConnectionMethod == method ? String(localized: "device.connection.selected", table: "Connections") : "")
                    .accessibilityIdentifier("deviceConnectionChoice_\(method.rawValue)")
                    if method != methods.last { Divider().padding(.leading, 58) }
                }
            }
        }
    }

    private var picker: some View {
        Button { showsMethods = true } label: {
            DeviceSettingsRow(embedded: embedded) {
                HStack(spacing: 12) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("device.connectionMethod").fontWeight(.medium)
                            Text(model.deviceConnectionMethod.selectionTitle).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("device.connectionMethod").fontWeight(.medium)
                        Spacer(minLength: 8)
                        Text(model.deviceConnectionMethod.selectionTitle)
                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .font(.subheadline).foregroundStyle(.primary).frame(minHeight: 24)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!canChange)
        .accessibilityLabel(Text("device.connectionMethod")).accessibilityValue(model.deviceConnectionMethod.selectionTitle)
        .accessibilityIdentifier("deviceConnectionMethodPicker")
    }
}

struct DeviceControlBackendPicker: View {
    var embedded = false
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsBackends = false
    @State private var pendingBackend: DeviceControlBackend?
    private let backends: [DeviceControlBackend] = [.coreDevice, .xcTest]
    private var systemVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }
    private var selectedBackend: DeviceControlBackend { model.deviceControlBackend.resolved(on: systemVersion) }
    private var selection: String { selectedBackend.selectionTitle }

    var body: some View {
        Button { showsBackends = true } label: {
            DeviceSettingsRow(embedded: embedded) {
                HStack(spacing: 12) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "device.backend.title", table: "Connections")).fontWeight(.medium)
                            Text(selection).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(String(localized: "device.backend.title", table: "Connections")).fontWeight(.medium)
                        Spacer(minLength: 8)
                        Text(selection).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .font(.subheadline).foregroundStyle(.primary).frame(minHeight: 24)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!model.canChangeDeviceControlBackend)
        .accessibilityLabel(String(localized: "device.backend.title", table: "Connections"))
        .accessibilityValue(selection)
        .accessibilityIdentifier("deviceControlBackendPicker")
        .sheet(isPresented: $showsBackends, onDismiss: {
            guard let backend = pendingBackend else { return }
            pendingBackend = nil
            Task { await model.selectDeviceControlBackend(backend) }
        }) {
            DeviceSelectionSheet(title: String(localized: "device.backend.title", table: "Connections")) {
                ForEach(backends, id: \.self) { backend in
                    let available = backend.isAvailable(on: systemVersion)
                    Button {
                        pendingBackend = backend
                        showsBackends = false
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: backend.selectionSymbol).font(.system(size: 22)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(backend.selectionTitle).font(.body.weight(.medium))
                                Text(available ? backend.selectionDetail : String(localized: "device.backend.requiresUpgrade", table: "Connections"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selectedBackend == backend {
                                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(.primary).padding(16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!available || !model.canChangeDeviceControlBackend)
                    .accessibilityValue(selectedBackend == backend ? String(localized: "device.connection.selected", table: "Connections") : "")
                    .accessibilityIdentifier("deviceControlBackendChoice_\(backend.rawValue)")
                    if backend != backends.last { Divider().padding(.leading, 58) }
                }
            }
        }
    }
}

private struct DeviceSelectionSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 240
    @State private var headerHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("common.done", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).font(.system(size: 17, weight: .semibold))
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                    .accessibilityIdentifier("deviceSelectionDoneButton")
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 16)
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { headerHeight = $0 }
            ScrollView {
                VStack(spacing: 0) { content }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(idealHeight: headerHeight + contentHeight)
        .background(EiscueStyle.background)
        // Measure the rows, not the scroll viewport. The system adds its safe area
        // and caps the detent on small screens; oversized text remains scrollable.
        .presentationDetents([.height(headerHeight + contentHeight)])
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.visible)
    }
}

private extension DeviceControlBackend {
    var selectionTitle: String {
        switch self {
        case .automatic: String(localized: "device.backend.automatic", table: "Connections")
        case .coreDevice: String(localized: "device.backend.coreDevice", table: "Connections")
        case .xcTest: String(localized: "device.backend.xctest", table: "Connections")
        }
    }
    var selectionDetail: String {
        switch self {
        case .automatic: String(localized: "device.backend.automaticDetail", table: "Connections")
        case .coreDevice: String(localized: "device.backend.coreDeviceDetail", table: "Connections")
        case .xcTest: String(localized: "device.backend.xctestDetail", table: "Connections")
        }
    }
    var selectionSymbol: String {
        switch self {
        case .automatic: "gearshape"
        case .coreDevice: "display"
        case .xcTest: "hand.tap"
        }
    }
}

private extension DeviceConnectionMethod {
    var selectionTitle: String {
        switch self {
        case .localVPN: String(localized: "device.appConnectionMethod")
        case .bluetoothBoard: String(localized: "device.connection.bluetoothTitle", table: "Connections")
        case .usbBoard: String(localized: "device.connection.usbTitle", table: "Connections")
        }
    }

    var selectionDetail: String {
        switch self {
        case .localVPN: String(localized: "device.connection.appSummary", table: "Connections")
        case .bluetoothBoard: String(localized: "device.connection.bluetoothSummary", table: "Connections")
        case .usbBoard: String(localized: "device.connection.usbSummary", table: "Connections")
        }
    }

    var selectionSymbol: String {
        switch self {
        case .localVPN: "iphone.gen3"
        case .bluetoothBoard: "keyboard"
        case .usbBoard: "cable.connector"
        }
    }
}

#if DEBUG
/// A local, reversible target for independent screenshot and input validation.
private struct ControlProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var count = 0
    @State private var input = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("probe.tapSection", systemImage: "hand.tap").font(.headline)
                            Text("probe.count \(count)")
                                .font(.system(.largeTitle, design: .rounded).monospacedDigit())
                                .accessibilityIdentifier("probeCount")
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { incrementButton; resetButton }
                                VStack(alignment: .leading, spacing: 12) { incrementButton; resetButton }
                            }
                            .controlSize(.large)
                        }
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("probe.inputSection", systemImage: "keyboard").font(.headline)
                            TextField("probe.inputPlaceholder", text: $input)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(EiscueStyle.background, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityIdentifier("probeInput")
                            Text(input.isEmpty ? String(localized: "probe.emptyInput") : input)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("probeEcho")
                        }
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("probe.swipeSection", systemImage: "hand.draw").font(.headline)
                                .padding(.bottom, 8)
                            ForEach(1...20, id: \.self) { index in
                                Text("probe.row \(index)")
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                                if index < 20 { Divider() }
                            }
                        }
                    }
                }
                .frame(maxWidth: 600)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(EiscueStyle.background)
            .navigationTitle("probe.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } } }
        }
    }

    private var incrementButton: some View {
        Button("probe.increment") { count += 1 }
            .buttonStyle(.glassProminent)
            .foregroundStyle(EiscueStyle.onAccent)
            .accessibilityIdentifier("probeIncrement")
    }

    private var resetButton: some View {
        Button("probe.reset") { count = 0 }.buttonStyle(.glass)
    }
}
#endif
