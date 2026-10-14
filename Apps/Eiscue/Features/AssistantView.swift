import EiscueAgentKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let openSidebar: () -> Void
    let revealSidebar: () -> Void
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
                VStack(alignment: .leading, spacing: 16) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(SidebarRevealGesture(isEnabled: !speech.isBusy) {
                endComposerInput()
                revealSidebar()
            })
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(model.isHoldingDeviceTranscript ? nil : .bottom, for: .sizeChanges)
            .onChange(of: model.displayedConversationFeed.count) {
                guard !model.isHoldingDeviceTranscript else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
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
        .onDisappear { endComposerInput() }
        .onAppear { if !isComposerFocused { dismissKeyboard() } }
    }

    private func endComposerInput() {
        isComposerFocused = false
        speech.cancel()
        dismissKeyboard()
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

    private func transcript(_ conversation: Conversation) -> some View {
        let feed = model.displayedConversationFeed
        let actionMessageIDs = ConversationFeedItem.latestActionMessageIDs(in: feed, isAssistantStreaming: !model.displayedStreamingText.isEmpty)
        return VStack(alignment: .leading, spacing: 16) {
            Text(conversation.createdAt, format: .dateTime.month().day())
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
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
                        .foregroundStyle(EiscueStyle.onAccent)
                    Button("assistant.endTask") { Task { await model.abandonInterruptedRun() } }
                        .buttonStyle(.glass)
                }
            }.padding(.vertical, 8)
        } else if model.activeRun == nil, let run = model.pausedRun {
            VStack(alignment: .leading, spacing: 10) {
                Label("run.paused", systemImage: "pause.circle").font(.subheadline.weight(.medium))
                Text(run.pauseReason?.detail ?? run.detail).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "run.paused.continue", table: "Runtime")) { Task { await model.continueInterruptedRun() } }
                        .buttonStyle(.glassProminent).accessibilityIdentifier("continuePausedRunButton")
                        .foregroundStyle(EiscueStyle.onAccent)
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
                    .foregroundStyle(EiscueStyle.onAccent)
                    .accessibilityIdentifier("stopRunButton")
                } else if !isVoiceMode {
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

private struct SidebarRevealGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let reveal: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: recognizer.view)
        guard translation.x < -60, abs(translation.x) > abs(translation.y) * 2 else { return }
        reveal()
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 2
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard touch.location(in: gestureRecognizer.view).x > 24 else { return false }
            var view = touch.view
            while let current = view, current !== gestureRecognizer.view {
                if current is UIControl || (current as? UITextView)?.isEditable == true { return false }
                // Horizontal code/image scrollers keep their own navigation gesture.
                if let scroll = current as? UIScrollView,
                   scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let scroll = other.view as? UIScrollView else { return false }
            return other === scroll.panGestureRecognizer
        }
    }
}
