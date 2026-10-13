import EiscueDeviceKit
import SwiftUI
import UniformTypeIdentifiers

struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var importsIdentity = false
    @State private var confirmsForget = false
    @State private var showsProbe = false
    @State private var showsConnectionHelp = false
    @State private var previewImage: UIImage?
    @State private var showsPreview = false

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    deviceHeader
                    deviceControlPermission
                    DeviceConnectionMethodPicker()
                    if model.deviceConnectionMethod == .bluetoothBoard {
                        BluetoothBoardSetupView()
                    } else {
                        connectionCard
                    }
                    if model.deviceConnectionMethod != .bluetoothBoard && model.isDeviceReady {
                        screenPreview
                    }
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
            .toolbar {
                if model.deviceConnectionMethod != .bluetoothBoard {
                    ToolbarItem(placement: .topBarTrailing) { connectionOptions }
                }
            }
            .onAppear { model.refreshPairingTransfer() }
            .fileImporter(isPresented: $importsIdentity, allowedContentTypes: [.json, .data]) { result in
                if case .success(let url) = result { Task { await model.importPairingIdentity(url) } }
                if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
            }
            .confirmationDialog("device.removePairingWarning", isPresented: $confirmsForget, titleVisibility: .visible) {
                Button("device.removeIdentity", role: .destructive) { Task { await model.forgetPairingIdentity() } }
            }
            .sheet(isPresented: $showsProbe) { ControlProbeView() }
            .sheet(isPresented: $showsConnectionHelp) { connectionHelpSheet }
            .sheet(isPresented: $showsPreview) {
                if let previewImage { DeviceScreenPreview(image: previewImage) }
            }
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
        .padding(.horizontal, 4)
    }

    private var deviceHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: model.device.platform == .iPadOS ? "ipad" : "iphone.gen3")
                .font(.system(size: 34, weight: .regular))
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.device.name).font(.headline)
                Text("\(model.device.platform == .iPadOS ? "iPadOS" : "iOS") \(model.device.systemVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.deviceConnectionMethod == .bluetoothBoard {
                    Label(model.connectionIndicator.title, systemImage: connectionStatusSymbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(model.connectionIndicator.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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

    private var connectionCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                if model.isDeviceReady {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("device.controlReady", systemImage: "checkmark.circle")
                                .font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("devicePairingComplete")
                            if model.deviceConnectionMethod == .localVPN {
                                Text(String(localized: "device.connection.vpnUsage", table: "Connections"))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("deviceVPNUsage")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        disconnectButton
                    }
                } else if model.isConnecting || model.isPairing || model.isManagingTunnel {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(model.isPairing ? String(localized: "device.pairing") : String(localized: "device.connecting"))
                            .font(.headline)
                    }
                } else if !model.hasPairingIdentity {
                    Text("device.firstConnection").font(.headline)
                    if model.deviceConnectionMethod != .localVPN {
                        Text("device.boardPairingRequired")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if !model.supportsSystemPairing {
                        Text("device.usbPairingRequired")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("usbPairingGuidance")
                    } else {
                        Text("device.systemPairingShort")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Label(model.isDeviceReady ? String(localized: "device.controlReady") : String(localized: "device.pairingSaved"),
                          systemImage: "checkmark.shield")
                        .font(.headline)
                        .accessibilityIdentifier("devicePairingComplete")
                    if !model.isDeviceReady {
                        Text("device.pairingSavedDetail")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if let code = model.pairingCode {
                    Text(code).font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("pairingCode")
                }

                if !model.isDeviceReady {
                    connectionActions.controlSize(.large)
                }
                if !model.isDeviceReady { connectionHelp }
                if showsConnectionMessage { connectionMessage }
            }
        }
    }

    @ViewBuilder private var connectionActions: some View {
        if model.isPairing || model.isConnecting || model.isManagingTunnel {
            disconnectButton
        } else {
            if !model.hasPairingIdentity && model.hasTransferredPairingIdentity {
                Button("device.importTransferredPairing") {
                    Task { await model.importTransferredPairingIdentity() }
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy)
                .accessibilityIdentifier("importTransferredPairingButton")
            } else if !model.hasPairingIdentity && (!model.supportsSystemPairing || model.deviceConnectionMethod != .localVPN) {
                Button("device.importIdentity") { importsIdentity = true }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(EiscueStyle.onAccent)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("importPairingIdentityButton")
            } else if !model.hasPairingIdentity {
                Button("device.startPairing") {
                    Task {
                        if !model.localTunnel.isConnected { await model.startLocalTunnel() }
                        if model.localTunnel.isConnected { model.startPairing() }
                    }
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy)
                .accessibilityIdentifier("startPairingButton")
            }
            if model.hasPairingIdentity {
                Button(model.deviceConnectionError == nil ? String(localized: "device.enableControl") : String(localized: "device.retryControl")) {
                    Task { await model.enableDeviceControl() }
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy)
                .accessibilityIdentifier("connectDeviceButton")
            }
        }
    }

    private var disconnectButton: some View {
        Button(String(localized: "device.connection.disconnect", table: "Connections")) {
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

    private var connectionOptions: some View {
        Menu {
            if model.isDeviceReady {
                Button { showsProbe = true } label: { Label("device.openProbe", systemImage: "hand.tap") }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("deviceProbeButton")
                Divider()
            }
            Button { showsConnectionHelp = true } label: {
                Label(String(localized: "device.connection.help", table: "Connections"), systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("deviceConnectionHelpButton")
            if model.deviceConnectionMethod == .localVPN && (model.localTunnel.isConnected || model.localTunnel.isTransitioning || model.isManagingTunnel) {
                Button("device.stopLocalConnection") { Task { await model.stopLocalTunnel() } }
                    .disabled(model.isStoppingTunnel)
            }
            if model.hasPairingIdentity {
                Button("device.removePairing", role: .destructive) { confirmsForget = true }
                    .disabled(model.isBusy)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(String(localized: "device.connection.options", table: "Connections"))
        .accessibilityIdentifier("deviceConnectionOptionsMenu")
    }

    private var connectionHelpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.deviceConnectionMethod == .localVPN { SurfaceCard { localConnection } }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            connectionHelp
                            if !model.hasPairingIdentity {
                                Text("device.developerModeDetail")
                                Text(model.supportsSystemPairing && model.deviceConnectionMethod == .localVPN ? String(localized: "device.pairingSetup") : String(localized: "device.usbPairingSetup"))
                                Text("device.compatibilityDetail")
                            }
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 600).padding(20).frame(maxWidth: .infinity)
            }
            .background(EiscueStyle.background)
            .navigationTitle(String(localized: "device.connection.help", table: "Connections"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { showsConnectionHelp = false }
                }
            }
            .alert("common.unableToComplete", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("common.understood") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }

    private var connectionHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(connectionDetail)
                .font(.caption).foregroundStyle(.secondary)
            if model.deviceConnectionMethod == .usbBoard {
                Text("device.boardHardwareRequirement")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("boardHardwareRequirement")
                Link(destination: URL(string: "https://github.com/LLLLLayer/Eiscue/tree/main/Firmware/NCM-Relay")!) {
                    Label("device.boardFirmwareGuide", systemImage: "arrow.up.right")
                }
                .font(.caption)
            } else if model.deviceConnectionMethod == .wirelessBoard {
                Text("device.wirelessBoardNetworkNote")
                    .font(.caption).foregroundStyle(.secondary)
                Link(destination: URL(string: "https://github.com/LLLLLayer/Eiscue/tree/main/Firmware/Passport-Relay")!) {
                    Label("device.boardFirmwareGuide", systemImage: "arrow.up.right")
                }
                .font(.caption)
            }
        }
    }

    private var showsConnectionMessage: Bool {
        !model.isDeviceReady || model.isConnecting || model.isPairing || model.isManagingTunnel || model.deviceConnectionError != nil
            || (model.deviceConnectionMethod == .localVPN && model.localTunnel.lastError != nil)
    }

    private var connectionMessage: some View {
        Text(model.connectionMessage)
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("deviceConnectionMessage")
    }

    private var connectionDetail: String {
        switch model.deviceConnectionMethod {
        case .bluetoothBoard: String(localized: "bluetooth.connectionDetail", table: "Bluetooth")
        case .localVPN: String(localized: "device.appConnectionDetail")
        case .usbBoard: String(localized: "device.boardConnectionDetail")
        case .wirelessBoard: String(localized: "device.wirelessBoardConnectionDetail")
        }
    }

    private var localConnection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("device.localConnection").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.localTunnel.statusTitle).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("localTunnelStatus")
            }
            Text("device.localConnectionShort").font(.caption).foregroundStyle(.secondary)
            if let error = model.localTunnel.lastError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.primary)
            }
            if model.localTunnel.isConnected || model.localTunnel.isTransitioning || model.isManagingTunnel {
                Button(model.isStoppingTunnel ? String(localized: "device.stoppingLocalConnection") : String(localized: "device.stopLocalConnection"), role: .destructive) {
                    Task { await model.stopLocalTunnel() }
                }
                .buttonStyle(.glass)
                .foregroundStyle(.primary)
                .disabled(model.isStoppingTunnel)
                .accessibilityIdentifier("stopLocalTunnelButton")
            } else {
                Button("device.startLocalConnection") { Task { await model.startLocalTunnel() } }
                    .buttonStyle(.glass)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("startLocalTunnelButton")
            }
        }
    }

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
}

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

struct DeviceConnectionMethodPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text("device.connectionMethod").foregroundStyle(.secondary)
                    picker
                }
            } else {
                HStack(spacing: 8) {
                    Text("device.connectionMethod").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    picker
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 4)
    }

    private var picker: some View {
        Picker("device.connectionMethod", selection: Binding(
            get: { model.deviceConnectionMethod },
            set: { method in Task { await model.selectDeviceConnectionMethod(method) } }
        )) {
            Text(String(localized: "bluetooth.method", table: "Bluetooth")).tag(DeviceConnectionMethod.bluetoothBoard)
            Text("device.appConnectionMethod").tag(DeviceConnectionMethod.localVPN)
            Text("device.boardConnectionMethod").tag(DeviceConnectionMethod.usbBoard)
            Text("device.wirelessBoardConnectionMethod").tag(DeviceConnectionMethod.wirelessBoard)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(model.isChangingDeviceConnectionMethod || model.isSaving || model.isStopping || model.isManagingTunnel || model.isStoppingTunnel || model.isImportingAttachments)
        .accessibilityIdentifier("deviceConnectionMethodPicker")
    }
}

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
