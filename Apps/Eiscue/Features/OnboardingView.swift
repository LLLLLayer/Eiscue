import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var showsModelSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in
                            Capsule().fill(index <= step ? EiscueStyle.accent : Color(.tertiarySystemFill))
                                .frame(height: 4)
                        }
                    }
                    .accessibilityLabel(text("setup.progress \(step + 1)"))

                    if step == 0 {
                        Image("MascotCutout").resizable().scaledToFit().frame(height: 220)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                        heading("setup.welcome", "setup.welcomeDetail")
                        row("bubble.left.and.bubble.right", "setup.chat", "setup.chatDetail")
                        row("hand.tap", "setup.device", "setup.deviceDetail")
                    } else if step == 1 {
                        symbol("sparkles")
                        heading("setup.model", "setup.modelDetail")
                        if model.hasConfiguredModel {
                            Label(text("setup.modelReady"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(EiscueStyle.accent)
                        }
                        Button { showsModelSettings = true } label: {
                            Label(text(model.hasConfiguredModel ? "setup.editModel" : "setup.configureModel"), systemImage: "key")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass).controlSize(.large)
                        .accessibilityIdentifier("onboardingConfigureModel")
                        Text(text("setup.modelHint")).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(text("setup.deviceSetup"))
                            .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        DeviceConnectionMethodPicker()
                        if model.deviceConnectionMethod == .bluetoothBoard {
                            BluetoothBoardSetupView()
                        } else {
                            DeveloperConnectionSetupView()
                        }
                        Text(text("setup.deviceLater")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(28).frame(maxWidth: .infinity)
            }
            .background(EiscueStyle.background)
            .safeAreaInset(edge: .bottom) {
                Button {
                    if step < 2 { step += 1 }
                    else { model.finishOnboarding() }
                } label: {
                    Text(text(step == 2 ? (model.isDeviceReady ? "setup.finish" : "setup.startChat") : step == 0 ? "setup.begin" : model.hasConfiguredModel ? "setup.continue" : "setup.configureLater"))
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy)
                .accessibilityIdentifier("onboardingContinueButton")
                .frame(maxWidth: 520).padding(.horizontal, 28).padding(.vertical, 16)
                .frame(maxWidth: .infinity).background(EiscueStyle.background)
            }
            .sheet(isPresented: $showsModelSettings) { ModelSettingsView() }
            .onChange(of: step) { _, value in
                if value == 2 { model.refreshPairingTransfer() }
            }
        }
    }

    private func text(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Onboarding") }
    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 48, weight: .light)).foregroundStyle(EiscueStyle.accent)
            .padding(.top, 12).accessibilityHidden(true)
    }
    private func heading(_ title: String.LocalizationValue, _ detail: String.LocalizationValue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text(title)).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(text(detail)).font(.body).foregroundStyle(.secondary)
        }
    }
    private func row(_ icon: String, _ title: String.LocalizationValue, _ detail: String.LocalizationValue) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(EiscueStyle.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(text(title)).font(.headline)
                Text(text(detail)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeveloperConnectionSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var importsIdentity = false
    @State private var showsHelp = false
    @State private var confirmsNewPairing = false
    @State private var showsFeedback = false

    private var usesSystemPairing: Bool { model.deviceConnectionMethod == .localVPN && model.supportsSystemPairing }
    private var isConnecting: Bool { model.isConnecting || model.isPairing || model.isManagingTunnel }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Label(statusTitle, systemImage: model.isDeviceReady ? "checkmark.circle" : "key")
                            .font(.headline)
                            .accessibilityIdentifier("onboardingPairingStatus")
                        Spacer(minLength: 0)
                        if model.hasPairingIdentity {
                            Button(text("setup.pairAgain")) { confirmsNewPairing = true }
                                .font(.caption).buttonStyle(.glass).controlSize(.small)
                                .disabled(model.isBusy)
                                .accessibilityIdentifier("onboardingReconnectPairingButton")
                        }
                    }
                    if !model.isDeviceReady {
                        Text(text(model.hasPairingIdentity ? "setup.savedPairingDetail" : usesSystemPairing ? "setup.systemPairingIntro" : "setup.computerPairingIntro"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let code = model.pairingCode {
                        Text(code).font(.system(.title, design: .monospaced).bold())
                            .accessibilityIdentifier("pairingCode")
                    }
                    if !model.isDeviceReady { connectionAction }
                    if isConnecting {
                        Text(model.connectionMessage).font(.caption).foregroundStyle(.secondary)
                    } else if showsFeedback, let error = model.deviceConnectionError ?? model.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("onboardingConnectionError")
                    }
                }
            }
            if model.deviceConnectionMethod == .localVPN {
                Text(String(localized: "device.connection.vpnUsage", table: "Connections"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                Text(text(model.deviceConnectionMethod == .usbBoard ? "setup.boardConnectionDetail" : "setup.wirelessBoardConnectionDetail"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            Button { showsHelp = true } label: {
                Label(text("setup.connectionHelp"), systemImage: "questionmark.circle")
                    .font(.subheadline).frame(minHeight: 44)
            }
            .buttonStyle(.plain).padding(.horizontal, 4)
            .accessibilityIdentifier("onboardingConnectionHelpButton")
        }
        .sheet(isPresented: $showsHelp) { connectionHelp }
        .confirmationDialog(text("setup.pairAgainConfirm"), isPresented: $confirmsNewPairing, titleVisibility: .visible) {
            Button(String(localized: "device.removeIdentity"), role: .destructive) {
                Task { showsFeedback = true; await model.forgetPairingIdentity() }
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: { Text(text("setup.pairAgainDetail")) }
        .fileImporter(isPresented: $importsIdentity, allowedContentTypes: [.json, .data]) { result in
            if case .success(let url) = result {
                showsFeedback = true
                Task { await model.importPairingIdentity(url) }
            }
            if case .failure(let error) = result { showsFeedback = true; model.errorMessage = error.localizedDescription }
        }
        .onChange(of: model.deviceConnectionMethod) { _, _ in showsFeedback = false }
    }

    private var statusTitle: String {
        if model.isDeviceReady { return String(localized: "device.controlReady") }
        return text(model.hasPairingIdentity ? "setup.savedPairing" : "setup.firstPairing")
    }

    @ViewBuilder private var connectionAction: some View {
        if isConnecting {
            HStack(spacing: 12) {
                ProgressView()
                Text(String(localized: model.isPairing ? "device.pairing" : "device.connecting"))
                    .font(.subheadline)
                Spacer()
                Button(String(localized: "common.cancel")) {
                    Task {
                        if model.deviceConnectionMethod == .localVPN { await model.stopLocalTunnel() }
                        else { await model.disconnectDevice() }
                    }
                }
                .buttonStyle(.glass).disabled(model.isStoppingTunnel || model.isStopping)
            }
        } else if model.hasPairingIdentity {
            Button(text("setup.connectDevice")) {
                Task { showsFeedback = true; await model.enableDeviceControl() }
            }
            .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
            .disabled(model.isBusy).accessibilityIdentifier("onboardingConnectDeviceButton")
        } else if model.hasTransferredPairingIdentity {
            Button(text("setup.importTransfer")) {
                Task { showsFeedback = true; await model.importTransferredPairingIdentity() }
            }
            .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
            .disabled(model.isBusy).accessibilityIdentifier("onboardingImportPairingButton")
        } else if usesSystemPairing {
            Button(String(localized: "device.startPairing")) {
                Task {
                    showsFeedback = true
                    if !model.localTunnel.isConnected { await model.startLocalTunnel() }
                    if model.localTunnel.isConnected { model.startPairing() }
                }
            }
            .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
            .disabled(model.isBusy).accessibilityIdentifier("startPairingButton")
        } else {
            Button(text("setup.importFile")) { importsIdentity = true }
                .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy).accessibilityIdentifier("onboardingImportPairingButton")
        }
    }

    private var connectionHelp: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(text("setup.preparationTitle")).font(.title2.bold())
                        .accessibilityIdentifier("onboardingConnectionHelp")
                    helpStep("1", "setup.developerMode", "setup.developerModeDetail")
                    if usesSystemPairing {
                        helpStep("2", "setup.pairing", "setup.systemPairingDetail")
                    } else {
                        helpStep("2", "setup.computerTrustTitle", "setup.computerTrustDetail")
                        helpStep("3", "setup.transferTitle", "setup.transferDetail")
                        Text(text("setup.computerRequiredNote")).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.deviceConnectionMethod == .localVPN {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(text("setup.vpnPermissionTitle")).font(.headline)
                                Text(text("setup.vpnPermissionDetail")).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    } else if model.deviceConnectionMethod == .wirelessBoard {
                        Text(text("setup.wirelessBoardNetworkNote"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(text("setup.savedSettingsTitle")).font(.headline)
                            Text(text("setup.savedSettingsDetail")).font(.subheadline).foregroundStyle(.secondary)
                            if model.deviceConnectionMethod == .localVPN {
                                Text(text("setup.savedVPNDetail")).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }
            .background(EiscueStyle.background)
            .navigationTitle(text("setup.connectionHelp")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done")) { showsHelp = false }
                        .accessibilityIdentifier("onboardingCloseConnectionHelpButton")
                }
            }
        }
    }

    private func helpStep(_ number: String, _ title: String.LocalizationValue, _ detail: String.LocalizationValue) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(text(title)).font(.headline)
                Text(text(detail)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func text(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Onboarding") }
}
