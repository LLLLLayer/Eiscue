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
                VStack(spacing: 24) {
                    if model.deviceConnectionMethod == .bluetoothBoard {
                        HStack(spacing: 12) {
                            Image(systemName: model.device.platform == .iPadOS ? "ipad" : "iphone.gen3")
                                .font(.title)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.device.name).font(.headline)
                                Text("\(model.device.platform == .iPadOS ? "iPadOS" : "iOS") \(model.device.systemVersion)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusLabel(title: model.connectionIndicator.title, color: model.connectionIndicator.color)
                        }.padding(.vertical, 8)
                    } else { deviceHeader }
                    connectionMethod
                    if model.deviceConnectionMethod == .bluetoothBoard {
                        BluetoothBoardSetupView()
                    } else {
                        connectionCard
                        advancedOptions
                    }
                }
                .frame(maxWidth: 600)
                .padding(24)
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

    private var deviceHeader: some View {
        VStack(spacing: 14) {
            Image(systemName: model.device.platform == .iPadOS ? "ipad" : "iphone.gen3")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(EiscueStyle.accent)
            Text(model.device.name).font(.title2.weight(.semibold))
            Text("\(model.device.platform == .iPadOS ? "iPadOS" : "iOS") \(model.device.systemVersion)")
                .font(.subheadline).foregroundStyle(.secondary)
            StatusLabel(title: model.connectionIndicator.title, color: model.connectionIndicator.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var connectionCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 18) {
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
                if model.deviceConnectionMethod == .localVPN && !model.localTunnel.isConnected && (model.hasPairingIdentity || model.supportsSystemPairing) {
                    Text("device.connectHint").font(.caption).foregroundStyle(.secondary)
                }

                Text(model.connectionMessage)
                    .font(.footnote).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("deviceConnectionMessage")
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
                .disabled(model.isBusy)
                .accessibilityIdentifier("importTransferredPairingButton")
            } else if !model.hasPairingIdentity && (!model.supportsSystemPairing || model.deviceConnectionMethod != .localVPN) {
                Button("device.importIdentity") { importsIdentity = true }
                    .buttonStyle(.glassProminent)
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
                .disabled(model.isBusy)
                .accessibilityIdentifier("startPairingButton")
            }
            if model.hasPairingIdentity {
                Button(model.deviceConnectionError == nil ? String(localized: "device.enableControl") : String(localized: "device.retryControl")) {
                    Task { await model.enableDeviceControl() }
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy)
                .accessibilityIdentifier("connectDeviceButton")
            }
        }
    }

    private var advancedOptions: some View {
        SurfaceCard {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 24) {
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

    private var connectionMethod: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("device.connectionMethod").font(.subheadline.weight(.semibold))
                DeviceConnectionMethodPicker()
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

    var body: some View {
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
            Form {
                Section("probe.tapSection") {
                    Text("probe.count \(count)").font(.largeTitle.monospacedDigit()).accessibilityIdentifier("probeCount")
                    Button("probe.increment") { count += 1 }.accessibilityIdentifier("probeIncrement")
                    Button("probe.reset") { count = 0 }
                }
                Section("probe.inputSection") {
                    TextField("probe.inputPlaceholder", text: $input).accessibilityIdentifier("probeInput")
                    Text(input.isEmpty ? String(localized: "probe.emptyInput") : input).accessibilityIdentifier("probeEcho")
                }
                Section("probe.swipeSection") {
                    ForEach(1...20, id: \.self) { index in Text("probe.row \(index)") }
                }
            }
            .navigationTitle("probe.title")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } } }
        }
    }
}
