import EiscueAgentKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    let openSidebar: () -> Void
    @FocusState private var isComposerFocused: Bool
    @State private var showsPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsFiles = false
    @State private var showsCamera = false
    @State private var speech = SpeechInputController()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let conversation = model.selectedConversation, !conversation.messages.isEmpty {
                        transcript(conversation)
                    } else { welcome }
                    if !model.streamingText.isEmpty {
                        AssistantMessageContent(text: model.streamingText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("streamingResponse")
                    }
                    runStatus
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24).padding(.top, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: model.selectedConversation?.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(EiscueStyle.background)
        .navigationTitle("Eiscue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("assistant.history", systemImage: "sidebar.left") {
                    isComposerFocused = false
                    speech.cancel()
                    openSidebar()
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("historyButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppDestination.device) {
                    DeviceConnectionIndicator(state: model.connectionIndicator, isIPad: model.device.platform == .iPadOS)
                }
                .accessibilityLabel("common.device")
                .accessibilityValue(model.connectionIndicator.title)
                .accessibilityIdentifier("deviceNavigationLink")
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
        .onChange(of: model.composerSessionID) {
            speech.cancel()
            showsPhotoPicker = false; showsFiles = false; showsCamera = false
        }
        .onDisappear { speech.cancel() }
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

    private func transcript(_ conversation: Conversation) -> some View {
        VStack(spacing: 22) {
            Text(conversation.createdAt, format: .dateTime.month().day()).font(.caption).foregroundStyle(.tertiary)
            ForEach(conversation.messages) { message in
                HStack(alignment: .top) {
                    if message.role == .user { Spacer(minLength: 36) }
                    VStack(alignment: .leading, spacing: 10) {
                        if message.role == .assistant { AssistantMessageContent(text: message.text) }
                        else if !message.text.isEmpty { Text(message.text) }
                        if !message.attachments.isEmpty {
                            ForEach(message.attachments) { attachment in
                                MessageAttachmentView(attachment: attachment)
                            }
                        }
                        if model.unsubmittedMessageIDs.contains(message.id) {
                            Text("assistant.unsubmittedMessage").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.body).textSelection(.enabled)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(message.role == .user ? EiscueStyle.accent.opacity(0.1) : EiscueStyle.surface,
                                in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("messageBubble")
                    if message.role != .user { Spacer(minLength: 36) }
                }
            }
        }
    }
    @ViewBuilder private var runStatus: some View {
        if let run = model.activeRun {
            SurfaceCard {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.state.title).font(.subheadline.weight(.medium))
                        if run.state == .failed || run.state == .interrupted {
                            Text(run.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("common.stop", role: .destructive) { Task { await model.stop() } }
                        .accessibilityIdentifier("stopRunButton")
                }
            }
        } else if model.needsRecovery {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("assistant.interrupted", systemImage: "pause.circle").font(.subheadline.weight(.semibold))
                    Text("assistant.recoveryDetail")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("assistant.resume") { Task { await model.continueInterruptedRun() } }
                            .buttonStyle(.glassProminent)
                            .accessibilityIdentifier("resumeRunButton")
                        Button("assistant.endTask") { Task { await model.abandonInterruptedRun() } }
                            .buttonStyle(.glass)
                    }
                }
            }
        } else if let run = model.selectedRuns.first {
            NavigationLink {
                RunHistoryView(conversationID: model.selectedConversationID)
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: run.state == .completed ? "checkmark.circle" : "exclamationmark.circle")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(run.state.title).font(.subheadline.weight(.medium))
                        if run.state == .failed || run.state == .interrupted {
                            Text(run.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .foregroundStyle(.primary)
                .padding(16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 18))
        }
    }

    private var composer: some View {
        @Bindable var model = model
        let dictationSessionID = model.composerSessionID
        let receiveDictation: @MainActor (String) -> Void = { transcript in
            guard model.composerSessionID == dictationSessionID else { return }
            appendDictation(transcript)
        }
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
            if model.scope == .control {
                HStack(spacing: 8) {
                    Label(text("composer.controlEnabled"), systemImage: "hand.tap").font(.caption)
                    Spacer()
                    if !model.isDeviceReady {
                        NavigationLink(value: AppDestination.device) { Text(text("composer.pairDevice")).font(.caption) }
                    }
                    Button { model.scope = .chat } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel(text("composer.controlOff")).disabled(model.isBusy)
                }
                .foregroundStyle(EiscueStyle.accent)
                .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
                .accessibilityIdentifier("deviceControlEnabled")
            }
            if speech.isBusy {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(EiscueStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(speech.statusText).font(.caption).foregroundStyle(.secondary)
                        if !speech.transcript.isEmpty { Text(speech.transcript).font(.subheadline).lineLimit(3) }
                    }
                    Spacer()
                    Button { speech.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel(text("composer.cancelVoice"))
                }
                .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
                .accessibilityIdentifier("speechPreview")
            }
            if let error = speech.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
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
                        Divider()
                        Toggle(isOn: Binding(get: { model.scope == .control }, set: { model.scope = $0 ? .control : .chat })) {
                            Label(text("composer.controlDevice"), systemImage: "hand.tap")
                        }.accessibilityIdentifier("deviceControlToggle")
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .disabled(model.isBusy || speech.isBusy)
                    .accessibilityLabel(text("composer.add")).accessibilityIdentifier("composerAddButton")
                    HStack(alignment: .bottom, spacing: 0) {
                        TextField("assistant.composerPlaceholder", text: $model.draft, axis: .vertical)
                            .lineLimit(1...5).font(.body).padding(.vertical, 14)
                            // Include the padded edges in the input's hit region above the glass.
                            .contentShape(Rectangle())
                            .focused($isComposerFocused).disabled(model.isBusy)
                            .accessibilityIdentifier("messageInput")
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                                guard !model.isBusy, model.draft.isEmpty else { return }
                                isComposerFocused = false
                                speech.toggle(onTranscript: receiveDictation)
                            })
                        SpeechInputButton(controller: speech, isDisabled: model.isBusy, onTranscript: receiveDictation)
                            .frame(width: 44, height: 48).disabled(model.isBusy)
                    }
                    .padding(.leading, 18).padding(.trailing, 4)
                    .frame(minHeight: 50)
                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
                    Button {
                        isComposerFocused = false
                        Task { await model.sendMessage() }
                    } label: {
                        Group {
                            if model.isSaving { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)) }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .disabled(!model.canSend || speech.isBusy)
                    .accessibilityLabel("assistant.send").accessibilityIdentifier("sendMessageButton")
                }
            }
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

private struct MessageAttachmentView: View {
    let attachment: AgentAttachment
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data = attachment.imageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(attachment.name)
            } else {
                Label(attachment.name, systemImage: "doc.text").font(.subheadline).foregroundStyle(EiscueStyle.accent)
            }
        }
    }
}
