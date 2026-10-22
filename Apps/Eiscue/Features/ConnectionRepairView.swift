import SwiftUI

struct ConnectionRepairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var microphone = MicrophoneCheckController()
    @State private var checkTask: Task<Void, Never>?
    @State private var connectionResult: DeviceConnectionRepairResult?
    @State private var microphoneResult: MicrophoneCheckController.Result?
    @State private var confirmsForget = false
    @State private var pairingResetError: String?

    var body: some View {
        List {
            Section {
                Button(action: startCheck) {
                    Label(text("connectionRepair.action"), systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .foregroundStyle(.primary)
                .disabled(checkTask != nil || !model.canRepairDeviceConnection)
                .accessibilityIdentifier("connectionRepairButton")
                if checkTask == nil, !model.canRepairDeviceConnection {
                    Text(text("connectionRepair.connection.busy"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if checkTask != nil {
                    ProgressView(text(connectionResult == nil ? "connectionRepair.releasing" : "connectionRepair.checkingMicrophone"))
                        .tint(.primary)
                        .accessibilityIdentifier("connectionRepairProgress")
                    if microphone.isChecking {
                        ProgressView(value: min(max(microphone.level, 0), 1))
                            .tint(.primary)
                            .accessibilityLabel(text("connectionRepair.microphoneLevel"))
                            .accessibilityIdentifier("connectionRepairMicrophoneLevel")
                    }
                }
            } header: {
                Text("connectionRepair.checkSection", tableName: "Connections")
                    .font(.caption)
            } footer: {
                Text("connectionRepair.explanation", tableName: "Connections")
            }
            .listRowBackground(EiscueStyle.surface)

            if let connectionResult {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        resultRow(title: text("connectionRepair.connection"), detail: connectionDetail(connectionResult),
                                  systemImage: "powerplug", identifier: "connectionRepairConnectionResult")
                        if let microphoneResult {
                            resultRow(title: text("connectionRepair.microphone"), detail: microphoneDetail(microphoneResult),
                                      systemImage: "mic", identifier: "connectionRepairMicrophoneResult")
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("connectionRepairResult")
                    if case .permissionDenied? = microphoneResult {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            Label(text("connectionRepair.openSettings"), systemImage: "arrow.up.right")
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("connectionRepairOpenSettingsButton")
                    }
                } header: {
                    Text("connectionRepair.resultsSection", tableName: "Connections")
                        .font(.caption)
                } footer: {
                    if checkTask == nil && connectionResult != .busy && connectionResult != .cancelled {
                        Text(connectionResult == .unconfirmed ? "connectionRepair.unconfirmedNextSteps" : "connectionRepair.completion",
                             tableName: "Connections")
                    }
                }
                .listRowBackground(EiscueStyle.surface)
            }

            if model.hasPairingIdentity {
                Section {
                    Button { confirmsForget = true } label: {
                        Label(text("connectionRepair.resetPairing"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .foregroundStyle(.primary)
                    .disabled(!canResetPairing)
                    .accessibilityIdentifier("removePairingButton")
                    if let pairingResetError {
                        Text(pairingResetError).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("connectionRepair.pairingSection", tableName: "Connections").font(.caption)
                } footer: {
                    Text(model.deviceSession.hasUnconfirmedRelease ? "connectionRepair.unconfirmedNextSteps" :
                            model.isDeviceReady ? "connectionRepair.disconnectBeforeReset" : "connectionRepair.resetPairingDetail",
                         tableName: "Connections")
                }
                .listRowBackground(EiscueStyle.surface)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(EiscueStyle.background)
        .navigationTitle(text("connectionRepair.title"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(String(localized: "setup.pairAgainConfirm", table: "Onboarding"), isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("device.removeIdentity", role: .destructive) {
                Task {
                    guard canResetPairing else { return }
                    pairingResetError = nil
                    await model.forgetPairingIdentity()
                    pairingResetError = model.deviceConnectionError
                }
            }
            .disabled(!canResetPairing)
        } message: {
            Text(String(localized: "setup.pairAgainDetail", table: "Onboarding"))
        }
        .onDisappear(perform: cancelCheck)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelCheck() }
        }
    }

    private var canResetPairing: Bool {
        model.hasPairingIdentity && checkTask == nil && !model.isBusy && !model.isDeviceReady &&
            !model.isConnecting && !model.deviceSession.hasUnconfirmedRelease
    }

    private func resultRow(title: String, detail: String, systemImage: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func startCheck() {
        guard checkTask == nil, model.canRepairDeviceConnection, scenePhase == .active else { return }
        connectionResult = nil
        microphoneResult = nil
        checkTask = Task { @MainActor in
            var ownsRepairGate = false
            defer {
                if ownsRepairGate { model.finishDeviceConnectionRepair() }
                checkTask = nil
            }
            guard !Task.isCancelled else {
                connectionResult = .cancelled
                return
            }
            let result = await model.repairDeviceConnection()
            connectionResult = result
            if case .busy = result { return }
            ownsRepairGate = true
            switch result {
            case .released, .notConnected, .unconfirmed:
                guard !Task.isCancelled, scenePhase == .active else {
                    microphoneResult = .cancelled
                    return
                }
                let checked = await microphone.check()
                switch checked {
                case .unavailable: microphoneResult = checked
                default: microphoneResult = Task.isCancelled ? .cancelled : checked
                }
            case .busy, .cancelled:
                break
            }
        }
    }

    private func cancelCheck() {
        checkTask?.cancel()
        microphone.cancel()
    }

    private func connectionDetail(_ result: DeviceConnectionRepairResult) -> String {
        switch result {
        case .released: text("connectionRepair.connection.released")
        case .notConnected: text("connectionRepair.connection.notConnected")
        case .unconfirmed: text("connectionRepair.connection.unconfirmed")
        case .busy: text("connectionRepair.connection.busy")
        case .cancelled: text("connectionRepair.connection.cancelled")
        }
    }

    private func microphoneDetail(_ result: MicrophoneCheckController.Result) -> String {
        switch result {
        case .signalDetected: text("connectionRepair.microphone.signalDetected")
        case .noSignal: text("connectionRepair.microphone.noSignal")
        case .permissionDenied: text("connectionRepair.microphone.permissionDenied")
        case .unavailable: text("connectionRepair.microphone.unavailable")
        case .cancelled: text("connectionRepair.microphone.cancelled")
        }
    }

    private func text(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Connections") }
}
