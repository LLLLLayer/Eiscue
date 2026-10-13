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
    @State private var isVoiceMode = false
    @State private var showsRunHistory = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let conversation = model.selectedConversation, !model.displayedConversationFeed.isEmpty {
                        transcript(conversation)
                    } else { welcome }
                    if !model.displayedStreamingText.isEmpty {
                        AssistantMessageContent(text: model.displayedStreamingText)
                            .equatable()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("streamingResponse")
                    }
                    if model.isShowingDeviceControlRun {
                        Label(chatText("chat.operatingDevice"), systemImage: "hand.tap")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                            .accessibilityIdentifier("deviceControlRunStatus")
                    } else if model.activeRun != nil || model.isSubmittingMessage { AssistantReplyIndicator() }
                    runStatus
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24).padding(.top, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(model.isHoldingDeviceTranscript ? nil : .bottom, for: .sizeChanges)
            .onChange(of: model.displayedConversationFeed.count) {
                guard !model.isHoldingDeviceTranscript else { return }
                if model.isShowingDeviceControlRun { proxy.scrollTo("bottom", anchor: .bottom) }
                else { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
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
            ToolbarItem(placement: .principal) {
                Menu {
                    Button("runs.conversationTitle", systemImage: "clock.arrow.circlepath") { showsRunHistory = true }
                        .accessibilityIdentifier("conversationRunHistoryButton")
                } label: {
                    HStack(spacing: 5) {
                        Text("Eiscue").font(.headline)
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
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
        .sheet(isPresented: $showsRunHistory) {
            NavigationStack {
                RunHistoryView(conversationID: model.selectedConversationID)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { showsRunHistory = false } } }
            }
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
        let feed = model.displayedConversationFeed
        let actionMessageIDs = ConversationFeedItem.latestActionMessageIDs(in: feed, isAssistantStreaming: !model.displayedStreamingText.isEmpty)
        return VStack(alignment: .leading, spacing: 22) {
            Text(conversation.createdAt, format: .dateTime.month().day())
                .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
            ForEach(feed) { item in
                switch item {
                case .message(let message): ChatMessageRow(message: message, showsActions: actionMessageIDs.contains(message.id))
                case .activity(let activity): ToolActivityRow(activity: activity, showsProgress: !model.isShowingDeviceControlRun)
                }
            }
        }
    }

    @ViewBuilder private var runStatus: some View {
        if model.activeRun == nil, model.needsRecovery {
            VStack(alignment: .leading, spacing: 10) {
                Label("assistant.interrupted", systemImage: "pause.circle").font(.subheadline.weight(.medium))
                Text("assistant.recoveryDetail").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("assistant.resume") { Task { await model.continueInterruptedRun() } }
                        .buttonStyle(.glassProminent).accessibilityIdentifier("resumeRunButton")
                    Button("assistant.endTask") { Task { await model.abandonInterruptedRun() } }
                        .buttonStyle(.glass)
                }
            }.padding(.vertical, 8)
        } else if model.activeRun == nil, let run = model.pausedRun {
            VStack(alignment: .leading, spacing: 10) {
                Label("run.paused", systemImage: "pause.circle").font(.subheadline.weight(.medium))
                Text(run.detail).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "run.paused.continue", table: "Runtime")) { Task { await model.continueInterruptedRun() } }
                        .buttonStyle(.glassProminent).accessibilityIdentifier("continuePausedRunButton")
                    Button(String(localized: "run.paused.end", table: "Runtime")) { Task { await model.abandonInterruptedRun() } }
                        .buttonStyle(.glass).accessibilityIdentifier("endPausedRunButton")
                }.disabled(model.isBusy)
            }.padding(.vertical, 8).accessibilityElement(children: .contain).accessibilityIdentifier("pausedRunStatus")
        } else if model.activeRun == nil, let run = model.selectedRuns.first, run.state == .failed {
            Label(run.detail, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
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
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            HStack(alignment: .bottom, spacing: 2) {
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
                if isVoiceMode {
                    SpeechInputButton(controller: speech, isDisabled: model.isBusy, onTranscript: receiveDictation)
                        .frame(maxWidth: .infinity)
                } else {
                    TextField("assistant.composerPlaceholder", text: $model.draft, axis: .vertical)
                        .lineLimit(1...5).font(.body).padding(.vertical, 11).padding(.horizontal, 4)
                        .frame(minHeight: 44).contentShape(Rectangle())
                        .focused($isComposerFocused).disabled(model.isSaving)
                        .accessibilityIdentifier("messageInput")
                }
                Button {
                    speech.cancel()
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
                    .accessibilityIdentifier("stopRunButton")
                } else if !isVoiceMode {
                    Button {
                        isComposerFocused = false
                        Task { await model.sendMessage() }
                    } label: {
                        Group {
                            if model.isSaving || model.isSubmittingMessage { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)) }
                        }
                        .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .disabled(!model.canSend || speech.isBusy)
                    .accessibilityLabel("assistant.send").accessibilityIdentifier("sendMessageButton")
                }
            }
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
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
