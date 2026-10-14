import EiscueAgentKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let sidebarDragID: Int
    let openSidebar: () -> Void
    @FocusState private var isComposerFocused: Bool
    @State private var showsPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsFiles = false
    @State private var showsCamera = false
    @State private var speech = SpeechInputController()
    @State private var isVoiceMode = false
    @State private var speechNotice: String?
    @State private var speechNoticeID: UUID?
    @State private var showsRunHistory = false

    var body: some View {
        AssistantTranscriptView { welcome }
        .id(model.selectedConversationID)
        .background(EiscueStyle.background)
        .navigationTitle("Eiscue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("assistant.history", systemImage: "sidebar.left") {
                    endComposerInput()
                    openSidebar()
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("historyButton")
            }
            ToolbarItem(placement: .principal) {
                Menu {
                    Button("runs.conversationTitle", systemImage: "clock.arrow.circlepath") {
                        endComposerInput(); showsRunHistory = true
                    }
                        .accessibilityIdentifier("conversationRunHistoryButton")
                    Divider()
                    ForEach(model.modelProfiles) { profile in
                        Button {
                            do { try model.selectModelProfile(profile.id) }
                            catch { model.errorMessage = model.safeError(error) }
                        } label: {
                            if model.selectedModelProfileID == profile.id {
                                Label(profile.displayName, systemImage: "checkmark")
                            } else { Text(profile.displayName) }
                        }
                        .disabled(!model.canManageModelProfiles)
                        .accessibilityIdentifier("switchModelProfile_\(profile.id.uuidString)")
                    }
                    Button(String(localized: "models.manage", table: "Models"), systemImage: "slider.horizontal.3") {
                        endComposerInput()
                        model.showsModelSettings = true
                    }
                    .disabled(!model.canManageModelProfiles)
                    .accessibilityIdentifier("manageModelProfilesButton")
                } label: {
                    HStack(spacing: 5) {
                        Text("Eiscue").font(.headline)
                        Image(systemName: "chevron.down").font(.caption2).opacity(0.6)
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                }.accessibilityLabel(chatText("chat.conversationMenu"))
                    .accessibilityIdentifier("conversationMenuButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppDestination.device) {
                    DeviceConnectionIndicator(state: model.connectionIndicator, isIPad: model.device.platform == .iPadOS)
                }
                .accessibilityLabel("common.device")
                .accessibilityValue(model.connectionIndicator.title)
                .accessibilityIdentifier("deviceNavigationLink")
                .simultaneousGesture(TapGesture().onEnded { endComposerInput() })
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $selectedPhotos,
                      maxSelectionCount: max(1, 4 - model.draftAttachments.count), matching: .images)
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            Task { await model.addAttachmentPhotos(items) }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: MessageAttachments.allowedFileTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.addAttachmentFiles(urls) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            EiscueCameraPicker(onCapture: { image in
                showsCamera = false
                Task { await model.addCameraImage(image) }
            }, onCancel: { showsCamera = false }).ignoresSafeArea()
        }
        .onChange(of: sidebarDragID) { endComposerInput() }
        .onChange(of: model.composerSessionID) {
            endComposerInput()
            showsPhotoPicker = false; showsFiles = false; showsCamera = false
        }
        .sheet(isPresented: $showsRunHistory) {
            NavigationStack {
                RunHistoryView(conversationID: model.selectedConversationID)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { showsRunHistory = false } } }
            }.toolImagePreviewHost()
        }
        .onChange(of: model.showsModelSettings) { _, shown in if shown { endComposerInput() } }
        .onChange(of: speech.errorMessage) { _, message in
            guard let message else { return }
            isVoiceMode = false
            showSpeechNotice(message)
            speech.clearError()
        }
        .onChange(of: model.isDictationBlockedByDeviceConnection) { _, blocked in
            if blocked && isVoiceMode {
                speech.cancel(); isVoiceMode = false
                showSpeechNotice(String(localized: "speech.error.remoteControl", table: "Speech"))
            }
        }
        .overlay(alignment: .top) {
            if let speechNotice {
                Text(speechNotice).font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.primary).padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .frame(maxWidth: 360).padding(.horizontal, 24).padding(.top, 8)
                    .allowsHitTesting(false).accessibilityIdentifier("speechNotice")
            }
        }
        .task(id: speechNoticeID) {
            guard speechNoticeID != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            speechNotice = nil
        }
        .onDisappear { endComposerInput() }
        .onAppear { if !isComposerFocused { dismissKeyboard() } }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--speech-diagnostics"), arguments.contains("--speech-capture-check") else { return }
            isVoiceMode = true
            speech.toggle(onTranscript: { _ in })
            do { try await Task.sleep(for: .seconds(10)) } catch { }
            speech.cancel()
        }
        #endif
    }

    private func endComposerInput() {
        isComposerFocused = false
        speech.cancel()
        speechNotice = nil; speechNoticeID = nil
        dismissKeyboard()
    }

    private func showSpeechNotice(_ message: String) {
        speechNotice = message; speechNoticeID = UUID()
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            Image("StickerWave").resizable().scaledToFit().frame(width: 112, height: 112).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text("assistant.welcome")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("welcomeTitle")
                Text("assistant.welcomeDetail").font(.subheadline).foregroundStyle(.secondary)
                if !model.hasConfiguredModel {
                    Button("assistant.configureModel") { model.showsModelSettings = true }
                        .font(.subheadline.weight(.medium)).padding(.top, 4)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                suggestion(symbol: "magnifyingglass", title: String(localized: "assistant.findInformation"), prompt: String(localized: "assistant.findInformationPrompt"))
                suggestion(symbol: "checklist", title: String(localized: "assistant.completeTask"), prompt: String(localized: "assistant.completeTaskPrompt"))
            }
        }.padding(.vertical, 24)
    }

    private func suggestion(symbol: String, title: String, prompt: String) -> some View {
        Button {
            model.draft = prompt
            isComposerFocused = true
        } label: {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.isBusy || speech.isBusy)
    }

    private var composer: some View {
        @Bindable var model = model
        let dictationSessionID = model.composerSessionID
        let receiveDictation: @MainActor (String) -> Void = { transcript in
            guard model.composerSessionID == dictationSessionID else { return }
            appendDictation(transcript)
            isVoiceMode = false
            isComposerFocused = true
        }
        let editor = TextField("assistant.composerPlaceholder", text: $model.draft, axis: .vertical)
            .lineLimit(1...5).font(.body).padding(.vertical, 11).padding(.horizontal, 4)
            .frame(minHeight: 44).contentShape(Rectangle())
            .focused($isComposerFocused).disabled(model.isSaving)
            .accessibilityIdentifier("messageInput")
        return VStack(spacing: 10) {
            if !model.draftAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.draftAttachments) { attachment in
                            HStack(spacing: 8) {
                                if let data = attachment.imageData, let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Image(systemName: "doc.text").foregroundStyle(EiscueStyle.accent)
                                }
                                Text(attachment.name).font(.caption).lineLimit(1).frame(maxWidth: 120)
                                Button { model.removeDraftAttachment(id: attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .accessibilityLabel(text("composer.removeAttachment"))
                                .disabled(model.isBusy)
                            }.padding(8).background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.scrollIndicators(.hidden).accessibilityIdentifier("draftAttachments")
            }
            if model.isImportingAttachments {
                HStack { ProgressView(); Text(text("composer.importing")).font(.caption); Spacer() }
                    .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            HStack(alignment: .bottom, spacing: 2) {
                if speech.isBusy {
                    Button { speech.cancel() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(text("composer.cancelVoice"))
                    .accessibilityIdentifier("cancelDictationButton")
                } else {
                    Menu {
                        Button(text("composer.photos"), systemImage: "photo.on.rectangle") { isComposerFocused = false; showsPhotoPicker = true }
                            .disabled(!model.canAddAttachments)
                        Button(text("composer.camera"), systemImage: "camera") {
                            isComposerFocused = false
                            let sessionID = model.composerSessionID
                            Task {
                                do {
                                    try await AttachmentCamera.requestAccess()
                                    guard model.composerSessionID == sessionID, !model.isBusy else { return }
                                    showsCamera = true
                                }
                                catch { model.errorMessage = error.localizedDescription }
                            }
                        }.disabled(!model.canAddAttachments)
                        Button(text("composer.files"), systemImage: "doc") { isComposerFocused = false; showsFiles = true }
                            .disabled(!model.canAddAttachments)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy || speech.isBusy)
                    .accessibilityLabel(text("composer.add")).accessibilityIdentifier("composerAddButton")
                }
                ZStack(alignment: .bottom) {
                    // The same editor measures both modes, including a multiline draft.
                    if isVoiceMode {
                        editor.hidden()
                        SpeechInputButton(controller: speech, isDisabled: model.isBusy, hapticsEnabled: model.hapticsEnabled, onTranscript: receiveDictation)
                            .frame(maxWidth: .infinity)
                    } else { editor }
                }
                Button {
                    if !isVoiceMode && model.isDictationBlockedByDeviceConnection {
                        showSpeechNotice(String(localized: "speech.error.remoteControl", table: "Speech"))
                        return
                    }
                    speechNotice = nil; speechNoticeID = nil
                    if speech.isBusy { speech.stop() }
                    else { speech.clearError() }
                    isVoiceMode.toggle()
                    isComposerFocused = !isVoiceMode
                } label: {
                    Image(systemName: isVoiceMode ? "keyboard" : "waveform")
                        .font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.isBusy)
                .accessibilityLabel(String(localized: isVoiceMode ? "speech.keyboardMode" : "speech.voiceMode", table: "Speech"))
                .accessibilityIdentifier("speechInputButton")
                if model.activeRun != nil {
                    Button { Task { await model.stop() } } label: {
                        Label("common.stop", systemImage: "stop.fill")
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 30)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .foregroundStyle(EiscueStyle.onAccent)
                    .accessibilityIdentifier("stopRunButton")
                } else {
                    Button {
                        isComposerFocused = false
                        Task { await model.sendMessage() }
                    } label: {
                        Group {
                            if model.isSaving || model.isSubmittingMessage { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)) }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(ComposerSendButtonStyle())
                    .disabled(!model.canSend || isVoiceMode || speech.isBusy)
                    .accessibilityLabel("assistant.send").accessibilityIdentifier("sendMessageButton")
                }
            }
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .accessibilityElement(children: .contain)
            .contentShape(.accessibility, .rect(cornerRadius: 28))
            .accessibilityIdentifier("messageComposer")
        }
        .frame(maxWidth: 720).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 9)
        .frame(maxWidth: .infinity)
    }

    private func appendDictation(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        let separator = model.draft.isEmpty || model.draft.last?.isWhitespace == true ? "" : " "
        model.draft += separator + transcript
    }
    private func text(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Composer") }
}

private struct ComposerSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill = isEnabled ? Color.black : Color(white: 0.46)
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            // Keep the glyph white when disabled; the glass button style dims it.
            .background(fill, in: Circle())
            .glassEffect(.regular.tint(fill).interactive(isEnabled), in: .circle)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
