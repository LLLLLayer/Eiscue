import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var showsModelSettings = false
    @State private var importsIdentity = false
    @State private var showsPairingFeedback = false

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
                        Image("Mascot").resizable().scaledToFit().frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 32)).frame(maxWidth: .infinity)
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
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("onboardingConfigureModel")
                        Text(text("setup.modelHint")).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        symbol(model.device.platform == .iPadOS ? "ipad" : "iphone.gen3")
                        heading("setup.deviceSetup", "setup.deviceSetupDetail")
                        row("1.circle", "setup.developerMode", "setup.developerModeDetail")
                        row("2.circle", "setup.pairing", model.supportsSystemPairing ? "setup.systemPairingDetail" : "setup.usbPairingDetail")
                        if !model.supportsSystemPairing {
                            Link(destination: URL(string: "https://github.com/LLLLLayer/Eiscue/blob/main/docs/device-setup.md")!) {
                                Label(text("setup.computerGuide"), systemImage: "arrow.up.right")
                            }.font(.subheadline)
                        }
                        if model.hasPairingIdentity {
                            Label(text("setup.pairingReady"), systemImage: "checkmark.circle.fill")
                                .font(.subheadline).foregroundStyle(EiscueStyle.accent)
                        } else if model.hasTransferredPairingIdentity {
                            Button(text("setup.importTransfer")) {
                                showsPairingFeedback = true
                                Task { await model.importTransferredPairingIdentity() }
                            }
                                .buttonStyle(.bordered).disabled(model.isBusy)
                        } else {
                            Button(text("setup.importFile")) { importsIdentity = true }
                                .buttonStyle(.bordered).disabled(model.isBusy)
                        }
                        if showsPairingFeedback {
                            Text(model.connectionMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        row("3.circle", "setup.localConnection", "setup.localConnectionDetail")
                        if model.localTunnel.isConnected {
                            Label(text("setup.localReady"), systemImage: "checkmark.circle.fill")
                                .font(.subheadline).foregroundStyle(EiscueStyle.accent)
                        } else {
                            Button(text("setup.enableConnection")) { Task { await model.startLocalTunnel() } }
                                .buttonStyle(.bordered).disabled(model.isBusy)
                        }
                        if let error = model.localTunnel.lastError ?? model.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.red)
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
                    Text(text(step == 2 ? "setup.finish" : step == 0 ? "setup.begin" : model.hasConfiguredModel ? "setup.continue" : "setup.configureLater"))
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.isBusy)
                .accessibilityIdentifier("onboardingContinueButton")
                .frame(maxWidth: 520).padding(.horizontal, 28).padding(.vertical, 16)
                .frame(maxWidth: .infinity).background(EiscueStyle.background)
            }
            .toolbar {
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { step -= 1 } label: {
                            Image(systemName: "chevron.left")
                        }.accessibilityLabel(text("setup.back"))
                    }
                }
            }
            .sheet(isPresented: $showsModelSettings) { ModelSettingsView() }
            .onChange(of: step) { _, value in
                if value == 2 { model.refreshPairingTransfer() }
            }
            .fileImporter(isPresented: $importsIdentity, allowedContentTypes: [.json, .data]) { result in
                if case .success(let url) = result {
                    showsPairingFeedback = true
                    Task { await model.importPairingIdentity(url) }
                }
                if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
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
