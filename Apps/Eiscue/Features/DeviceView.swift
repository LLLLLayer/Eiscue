import EiscueDeviceKit
import SwiftUI
import UniformTypeIdentifiers

struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @State private var importsIdentity = false
    @State private var confirmsForget = false
    #if DEBUG
    @State private var showsProbe = false
    #endif
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
                    if model.deviceConnectionMethod != .bluetoothBoard {
                        connectionSupport
                        #if DEBUG
                        if model.isDeviceReady { debugSection }
                        #endif
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
            #if DEBUG
            .sheet(isPresented: $showsProbe) { ControlProbeView() }
            #endif
            .sheet(isPresented: $showsConnectionHelp) { connectionHelpSheet }
            .onChange(of: showsConnectionHelp) { _, isPresented in
                if !isPresented { model.refreshPairingTransfer() }
            }
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

    private var connectionSupport: some View {
        SurfaceCard {
            Button { showsConnectionHelp = true } label: {
                connectionSupportLabel(String(localized: "device.connection.help", table: "Connections"), symbol: "questionmark.circle")
            }
            .accessibilityIdentifier("deviceConnectionHelpButton")
            .buttonStyle(.plain)
        }
    }

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "device.debug.title", table: "Connections"))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("deviceDebugSectionTitle")
            SurfaceCard {
                Button { showsProbe = true } label: {
                    connectionSupportLabel(String(localized: "device.openProbe"), symbol: "hand.tap")
                }
                .buttonStyle(.plain).disabled(model.isBusy)
                .accessibilityIdentifier("deviceProbeButton")
            }
        }
    }
    #endif

    private func connectionSupportLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24)
            Text(title).font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 32).contentShape(Rectangle())
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
                    if !model.supportsSystemPairing || model.deviceConnectionMethod != .localVPN {
                        ComputerPairingHelpView()
                    }
                    if model.hasPairingIdentity {
                        Button("device.removePairing", role: .destructive) { confirmsForget = true }
                            .buttonStyle(.glass).disabled(model.isBusy)
                            .accessibilityIdentifier("removePairingButton")
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
            .confirmationDialog("device.removePairingWarning", isPresented: $confirmsForget, titleVisibility: .visible) {
                Button("device.removeIdentity", role: .destructive) { Task { await model.forgetPairingIdentity() } }
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
    @State private var showsMethods = false

    private let methods: [DeviceConnectionMethod] = [.localVPN, .bluetoothBoard, .usbBoard, .wirelessBoard]
    private var canChange: Bool {
        !model.isChangingDeviceConnectionMethod && !model.isSaving && !model.isStopping
            && !model.isManagingTunnel && !model.isStoppingTunnel && !model.isImportingAttachments
    }

    var body: some View {
        picker
        .sheet(isPresented: $showsMethods) {
            NavigationStack {
                List(methods, id: \.self) { method in
                    Button {
                        Task {
                            await model.selectDeviceConnectionMethod(method)
                            if model.deviceConnectionMethod == method { showsMethods = false }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: method.selectionSymbol).font(.title3).frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(method.selectionTitle).font(.body.weight(.medium))
                                Text(method.selectionDetail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if model.deviceConnectionMethod == method {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(.primary).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!canChange)
                    .accessibilityLabel(method.selectionTitle).accessibilityHint(method.selectionDetail)
                    .accessibilityValue(model.deviceConnectionMethod == method ? String(localized: "device.connection.selected", table: "Connections") : "")
                    .accessibilityIdentifier("deviceConnectionChoice_\(method.rawValue)")
                    .listRowBackground(EiscueStyle.surface)
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(EiscueStyle.background)
                .navigationTitle("device.connectionMethod").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") { showsMethods = false }
                    }
                }
            }
            .presentationDetents([.fraction(0.65), .large]).presentationDragIndicator(.visible)
        }
    }

    private var picker: some View {
        Button { showsMethods = true } label: {
            SurfaceCard {
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

private extension DeviceConnectionMethod {
    var selectionTitle: String {
        switch self {
        case .localVPN: String(localized: "device.appConnectionMethod")
        case .bluetoothBoard: String(localized: "device.connection.bluetoothTitle", table: "Connections")
        case .usbBoard: String(localized: "device.connection.usbTitle", table: "Connections")
        case .wirelessBoard: String(localized: "device.connection.wifiTitle", table: "Connections")
        }
    }

    var selectionDetail: String {
        switch self {
        case .localVPN: String(localized: "device.connection.appSummary", table: "Connections")
        case .bluetoothBoard: String(localized: "device.connection.bluetoothSummary", table: "Connections")
        case .usbBoard: String(localized: "device.connection.usbSummary", table: "Connections")
        case .wirelessBoard: String(localized: "device.connection.wifiSummary", table: "Connections")
        }
    }

    var selectionSymbol: String {
        switch self {
        case .localVPN: "iphone.gen3"
        case .bluetoothBoard: "keyboard"
        case .usbBoard: "cable.connector"
        case .wirelessBoard: "wifi"
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
