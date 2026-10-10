import EiscueAgentKit
import SwiftUI

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @State private var showsHistory = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let conversation = model.selectedConversation, !conversation.messages.isEmpty {
                            transcript(conversation)
                        } else {
                            welcome
                        }
                        if !model.streamingText.isEmpty {
                            Text(model.streamingText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                                .background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                                .accessibilityIdentifier("streamingResponse")
                        }
                        runStatus
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
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
                    Button("assistant.history", systemImage: "sidebar.left") { showsHistory = true }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("historyButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("assistant.newConversation", systemImage: "square.and.pencil") {
                        model.newConversation()
                        isComposerFocused = false
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("newConversationButton")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .sheet(isPresented: $showsHistory) { ConversationHistoryView() }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            IceMark(size: 88)
            VStack(alignment: .leading, spacing: 12) {
                Text("assistant.welcome")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("welcomeTitle")
                Text("assistant.welcomeDetail")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !model.hasConfiguredModel {
                    Button("assistant.configureModel") { model.showsModelSettings = true }
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 4)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                suggestion(symbol: "magnifyingglass", title: String(localized: "assistant.findInformation"),
                           prompt: String(localized: "assistant.findInformationPrompt"))
                suggestion(symbol: "checklist", title: String(localized: "assistant.completeTask"),
                           prompt: String(localized: "assistant.completeTaskPrompt"))
            }
        }
        .padding(.vertical, 24)
    }

    private func suggestion(symbol: String, title: String, prompt: String) -> some View {
        Button {
            model.draft = prompt
            isComposerFocused = true
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
    }

    private func transcript(_ conversation: Conversation) -> some View {
        VStack(spacing: 22) {
            Text(conversation.createdAt, format: .dateTime.month().day())
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(conversation.messages) { message in
                HStack {
                    if message.role == .user { Spacer(minLength: 36) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.text)
                        if model.unsubmittedMessageIDs.contains(message.id) {
                            Text("assistant.unsubmittedMessage").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(
                            message.role == .user ? EiscueStyle.accent.opacity(0.1) : EiscueStyle.surface,
                            in: RoundedRectangle(cornerRadius: 22)
                        )
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
                        Text(run.detail).font(.caption).foregroundStyle(.secondary)
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
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("resumeRunButton")
                        Button("assistant.endTask") { Task { await model.abandonInterruptedRun() } }
                            .buttonStyle(.bordered)
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
                        Text(run.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .foregroundStyle(.primary)
                .padding(16)
                .background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private var composer: some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Picker("assistant.taskScope", selection: $model.scope) {
                        ForEach(TaskScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }
                    Picker("assistant.workflow", selection: $model.selectedSkillID) {
                        Text("assistant.noSkill").tag(String?.none)
                        ForEach(model.skills) { skill in Text(skill.name).tag(Optional(skill.id)) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text(model.scope.title)
                        if model.selectedSkill != nil {
                            Image(systemName: "list.bullet.clipboard")
                        }
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                }
                .accessibilityIdentifier("taskScopePicker")
                Spacer()
                if !model.modelSettings.model.isEmpty {
                    Text(model.modelSettings.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .disabled(model.isBusy)
            HStack(alignment: .bottom, spacing: 12) {
                TextField("assistant.composerPlaceholder", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .padding(.vertical, 11)
                    .focused($isComposerFocused)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("messageInput")
                Button {
                    isComposerFocused = false
                    Task { await model.sendMessage() }
                } label: {
                    Group {
                        if model.isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(model.canSend ? EiscueStyle.accent : Color.secondary.opacity(0.25), in: Circle())
                }
                .disabled(!model.canSend)
                .accessibilityLabel("assistant.send")
                .accessibilityIdentifier("sendMessageButton")
                .padding(.bottom, 3)
            }
            .padding(.leading, 18)
            .padding(.trailing, 9)
            .padding(.vertical, 7)
            .background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.06))
            }
            if model.scope != .chat {
                Text(model.scope.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity)
        .background(EiscueStyle.background)
    }
}

private struct ConversationHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.conversations.isEmpty {
                    ContentUnavailableView("assistant.emptyHistory", systemImage: "bubble.left.and.bubble.right", description: Text("assistant.emptyHistoryDetail"))
                } else {
                    List {
                        ForEach(model.conversations) { conversation in
                            Button {
                                model.select(conversation)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bubble.left")
                                        .foregroundStyle(EiscueStyle.accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(conversation.title)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if conversation.id == model.selectedConversationID {
                                        Image(systemName: "checkmark").foregroundStyle(EiscueStyle.accent)
                                    }
                                }
                                .padding(.vertical, 5)
                            }
                            .disabled(model.isBusy)
                            .swipeActions {
                                Button("common.delete", role: .destructive) {
                                    Task { await model.delete(conversation) }
                                }
                                .disabled(model.isBusy)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("assistant.history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
    }
}
