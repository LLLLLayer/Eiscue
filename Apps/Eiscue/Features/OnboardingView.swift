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
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsNewPairing = false
    @State private var showsFeedback = false

    private var usesSystemPairing: Bool { model.deviceConnectionMethod == .localVPN && model.supportsSystemPairing }
    private var isConnecting: Bool { model.isConnecting || model.isPairing || model.isManagingTunnel }
    private var shouldRefreshPairingTransfer: Bool { scenePhase == .active && !model.hasPairingIdentity }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Label(statusTitle, systemImage: model.isDeviceReady ? "checkmark.circle" : "key")
                            .font(.headline)
                            .accessibilityIdentifier("onboardingPairingStatus")
                        Spacer(minLength: 0)
                        if model.deviceConnectionMethod == .localVPN && !isConnecting
                            && (model.localTunnel.isConnected || model.localTunnel.isTransitioning) {
                            Button(String(localized: "device.connection.disconnect", table: "Connections")) {
                                Task { await model.stopLocalTunnel() }
                            }
                            .buttonStyle(.glass).controlSize(.small)
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(model.isStoppingTunnel || model.isStopping)
                            .accessibilityIdentifier("onboardingDisconnectDeviceButton")
                        } else if model.hasPairingIdentity {
                            Button(text("setup.pairAgain")) { confirmsNewPairing = true }
                                .font(.caption).buttonStyle(.glass).controlSize(.small)
                                .disabled(model.isBusy)
                                .accessibilityIdentifier("onboardingReconnectPairingButton")
                        }
                    }
                    if !model.isDeviceReady && !isConnecting {
                        if model.hasPairingIdentity {
                            Text(text("setup.savedPairingDetail")).font(.subheadline).foregroundStyle(.secondary)
                        } else if model.hasTransferredPairingIdentity {
                            Text(text("setup.inlineTransferReady")).font(.subheadline).foregroundStyle(.secondary)
                        } else if usesSystemPairing {
                            Text(text("setup.inlineSystemPreparation")).font(.subheadline).foregroundStyle(.secondary)
                            Text(text("setup.systemPairingDetail")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            if model.deviceConnectionMethod == .localVPN {
                                Text(text("setup.systemPairingAvailability")).font(.caption).foregroundStyle(.secondary)
                            }
                            ComputerPairingHelpView()
                        }
                    }
                    if let code = model.pairingCode {
                        Text(code).font(.system(.title, design: .monospaced).bold())
                            .accessibilityIdentifier("pairingCode")
                    }
                    if !model.isDeviceReady && !isConnecting && !usesSystemPairing {
                        PairingSetupStepTitle(number: model.hasPairingIdentity ? 5 : 4,
                                              title: text(model.hasPairingIdentity ? "setup.stepConnectTitle" : "setup.stepImportTitle"))
                        if !model.hasPairingIdentity && !model.hasTransferredPairingIdentity {
                            Text(text("setup.stepImportWaiting")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !model.isDeviceReady { connectionAction }
                    if !model.hasPairingIdentity && !isConnecting && !usesSystemPairing {
                        PairingSetupStepTitle(number: 5, title: text("setup.stepConnectTitle"))
                        Text(text("setup.stepConnectAfterImport")).font(.caption).foregroundStyle(.secondary)
                    }
                    if isConnecting {
                        Text(model.connectionMessage).font(.caption).foregroundStyle(.secondary)
                    } else if showsFeedback, let error = model.deviceConnectionError ?? model.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("onboardingConnectionError")
                    }
                }
            }
            if model.deviceConnectionMethod == .usbBoard {
                Text(text("setup.boardConnectionDetail"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
        .task(id: shouldRefreshPairingTransfer) {
            guard shouldRefreshPairingTransfer else { return }
            while !Task.isCancelled {
                model.refreshPairingTransfer()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
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
        if model.hasPairingIdentity { return text("setup.savedPairing") }
        return text(model.hasTransferredPairingIdentity ? "setup.transferReadyTitle" : "setup.firstPairing")
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
        } else {
            if usesSystemPairing {
                Button(String(localized: "device.startPairing")) {
                    Task {
                        showsFeedback = true
                        if !model.localTunnel.isConnected { await model.startLocalTunnel() }
                        if model.localTunnel.isConnected { model.startPairing() }
                    }
                }
                .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy).accessibilityIdentifier("startPairingButton")
            }
            if model.hasTransferredPairingIdentity {
                Button(text("setup.importTransfer")) {
                    Task { showsFeedback = true; await model.importTransferredPairingIdentity() }
                }
                .buttonStyle(.glassProminent).foregroundStyle(EiscueStyle.onAccent)
                .disabled(model.isBusy).accessibilityIdentifier("onboardingImportPairingButton")
            } else {
                Button(text("setup.chooseExistingFile")) { importsIdentity = true }
                    .buttonStyle(.glass)
                .disabled(model.isBusy).accessibilityIdentifier("onboardingImportPairingButton")
            }
        }
    }

    private func text(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Onboarding") }
}
