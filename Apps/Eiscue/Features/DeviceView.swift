import EiscueDeviceKit
import SwiftUI
import UniformTypeIdentifiers

struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var importsIdentity = false
    @State private var confirmsForget = false
    @State private var showsProbe = false
    @State private var showsAdvanced = false

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
                    if model.deviceConnectionMethod != .bluetoothBoard {
                        advancedOptions
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
            .onAppear { model.refreshPairingTransfer() }
            .fileImporter(isPresented: $importsIdentity, allowedContentTypes: [.json, .data]) { result in
                if case .success(let url) = result { Task { await model.importPairingIdentity(url) } }
                if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
            }
            .confirmationDialog("device.removePairingWarning", isPresented: $confirmsForget, titleVisibility: .visible) {
                Button("device.removeIdentity", role: .destructive) { Task { await model.forgetPairingIdentity() } }
            }
            .sheet(isPresented: $showsProbe) { ControlProbeView() }
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
                Label(model.connectionIndicator.title, systemImage: connectionStatusSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.connectionIndicator.color)
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
                if model.isConnecting || model.isPairing || model.isManagingTunnel {
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

                connectionActions
                    .controlSize(.large)
                if !model.isDeviceReady { connectionHelp }
                if showsConnectionMessage { connectionMessage }
            }
        }
    }

    @ViewBuilder private var connectionActions: some View {
        if model.isDeviceReady || model.isPairing || model.isConnecting {
            Button("device.disconnectAndStop", role: .destructive) { Task { await model.disconnectDevice() } }
                .buttonStyle(.glass)
                .foregroundStyle(.primary)
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

    private var advancedOptions: some View {
        SurfaceCard {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 18) {
                    if !showsConnectionMessage { connectionMessage }
                    if model.isDeviceReady { connectionHelp }
                    if model.deviceConnectionMethod == .localVPN {
                        localConnection
                        Divider()
                    }
                    if !model.hasPairingIdentity {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("device.preparation").font(.subheadline.weight(.semibold))
                            Text("device.developerModeDetail")
                            Text(model.supportsSystemPairing && model.deviceConnectionMethod == .localVPN ? String(localized: "device.pairingSetup") : String(localized: "device.usbPairingSetup"))
                            Text("device.compatibilityDetail")
                        }
                        .font(.caption).foregroundStyle(.secondary)

                        Button("device.importIdentity") { importsIdentity = true }
                            .buttonStyle(.glass)
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("importPairingIdentityFromFilesButton")
                    }
                    if model.isDeviceReady {
                        verification
                    }
                    if model.hasPairingIdentity {
                        Button("device.removePairing", role: .destructive) { confirmsForget = true }
                            .buttonStyle(.glass)
                            .foregroundStyle(.primary)
                            .disabled(model.isBusy)
                    }
                }
                .padding(.top, 16)
            } label: {
                Label("device.advanced", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("deviceAdvancedOptions")
            }
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

    private var verification: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("device.verifyControl").font(.subheadline.weight(.semibold))
            Button("device.captureScreenshot") { Task { await model.previewScreenshot() } }
                .buttonStyle(.glass)
                .disabled(!model.isDeviceReady || model.isBusy || model.isConnecting)
            Button("device.openProbe") { showsProbe = true }
                .buttonStyle(.glass)
                .disabled(model.isBusy)
            if let frame = model.screenshot, let image = UIImage(data: frame.data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("\(frame.width) × \(frame.height) · \(frame.capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
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
