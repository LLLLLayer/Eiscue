import EiscueAgentKit
import SwiftUI
import UIKit

struct ChatMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: AgentMessage
    var showsActions = true
    @State private var showsSelection = false
    @State private var didCopy = false
    @State private var canShareAttachments = false
    @State private var checkedAttachments = false
    @State private var isPreparingShare = false
    @State private var sharePayload: MessageSharePayload?
    @State private var sharePreparation: Task<Void, Never>?

    private var hasText: Bool { !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canShare: Bool { message.attachments.isEmpty ? hasText : canShareAttachments }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 42) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    if message.role == .assistant { AssistantMessageContent(text: message.text).equatable() }
                    else if !message.text.isEmpty { Text(verbatim: message.text).textSelection(.enabled) }
                    ForEach(message.attachments) { attachment in ChatAttachmentView(attachment: attachment) }
                    if model.unsubmittedMessageIDs.contains(message.id) {
                        Text("assistant.unsubmittedMessage").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, message.role == .user ? 16 : 0)
                .padding(.vertical, message.role == .user ? 12 : 2)
                .background(message.role == .user ? Color.primary.opacity(0.07) : .clear,
                            in: RoundedRectangle(cornerRadius: 22))
                .contentShape(Rectangle())
                .contextMenu { messageMenu }
                .accessibilityElement(children: .contain).accessibilityIdentifier("messageBubble")
                if showsActions {
                    HStack(spacing: 2) {
                        Text(message.createdAt, format: .dateTime.hour().minute())
                            .font(.caption2.monospacedDigit()).accessibilityIdentifier("messageTime")
                        if hasText {
                            Button { copy() } label: {
                                Image(systemName: didCopy ? "checkmark" : "doc.on.doc").frame(width: 24, height: 32).contentShape(Rectangle())
                            }
                            .accessibilityLabel(chatText(didCopy ? "chat.copied" : "chat.copy"))
                            .accessibilityIdentifier(message.role == .user ? "userCopyMessageButton" : "copyMessageButton")
                        }
                        Button { share() } label: {
                            Group {
                                if isPreparingShare { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "square.and.arrow.up") }
                            }.frame(width: 24, height: 32).contentShape(Rectangle())
                        }
                        .disabled(!canShare || isPreparingShare || sharePayload != nil)
                        .accessibilityLabel(chatText("chat.share"))
                        .accessibilityIdentifier(message.role == .user ? "userShareMessageButton" : "shareMessageButton")
                    }
                    .font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, message.role == .user ? 8 : 0)
                }
                if !message.attachments.isEmpty, checkedAttachments, !canShareAttachments {
                    Text(String(localized: "messageSharing.unavailable", table: "MessageSharing"))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("messageShareUnavailable")
                }
            }
            if message.role != .user { Spacer(minLength: 0) }
        }
        .background(alignment: message.role == .user ? .bottomTrailing : .bottomLeading) {
            // Older messages still share from their context menu after their
            // visible footer moves to the sender's newest message.
            MessageActivityPresenter(payload: sharePayload) { id, hasError in
                if sharePayload?.id == id { sharePayload = nil }
                if hasError { model.errorMessage = MessageSharingError.delivery.localizedDescription }
            }.frame(width: 30, height: 32).allowsHitTesting(false)
        }
        .sheet(isPresented: $showsSelection) {
            NavigationStack {
                SelectableMessageText(text: message.role == .assistant ? ChatMarkdownParser.plainText(message.text) : message.text)
                    .padding(.horizontal, 18).background(EiscueStyle.background)
                    .navigationTitle(chatText("chat.selectText"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { showsSelection = false } } }
            }.presentationDetents([.large])
        }
        .task(id: message.attachments.map(\.id)) {
            checkedAttachments = false
            let available = await model.messageAttachments.canShareAttachments(message.attachments)
            guard !Task.isCancelled else { return }
            canShareAttachments = available
            checkedAttachments = true
        }
        .onDisappear { sharePreparation?.cancel() }
    }

    @ViewBuilder private var messageMenu: some View {
        if hasText {
            Button(chatText("chat.copy"), systemImage: "doc.on.doc") { copy() }
            Button(chatText("chat.selectText"), systemImage: "selection.pin.in.out") { showsSelection = true }
                .accessibilityIdentifier("selectMessageTextButton")
        }
        Button(chatText("chat.share"), systemImage: "square.and.arrow.up") { share() }
            .disabled(!canShare || isPreparingShare || sharePayload != nil)
        if message.role == .user, hasText {
            Button(chatText("chat.useAsDraft"), systemImage: "pencil") { model.draft = message.text }
                .disabled(model.isBusy)
        }
        NavigationLink { RunHistoryView(conversationID: model.selectedConversationID) } label: {
            Label("runs.conversationTitle", systemImage: "clock.arrow.circlepath")
        }.accessibilityIdentifier("messageRunHistoryButton")
    }

    private func copy() {
        guard hasText else { return }
        UIPasteboard.general.string = message.text
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func share() {
        guard canShare, !isPreparingShare, sharePayload == nil else { return }
        isPreparingShare = true
        sharePreparation = Task { @MainActor in
            var prepared: MessageSharePayload?
            defer { isPreparingShare = false; sharePreparation = nil }
            do {
                prepared = try await model.messageAttachments.prepareShare(message)
                try Task.checkCancellation()
                sharePayload = prepared
            } catch {
                prepared?.cleanup()
                if !(error is CancellationError) { model.errorMessage = error.localizedDescription }
            }
        }
    }
}

/// Native UITextView provides range selection and the standard Copy/Share menu,
/// including selection handles; opening a message never copies the whole text.
private struct SelectableMessageText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .init(top: 20, left: 0, bottom: 20, right: 0)
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "selectableMessageText"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
    }
}

struct ChatAttachmentView: View {
    let attachment: AgentAttachment
    var body: some View {
        if let data = attachment.imageData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(attachment.name)
        } else {
            Label(attachment.name, systemImage: "doc.text").font(.subheadline).foregroundStyle(.primary)
        }
    }
}

struct ToolActivityRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let activity: ToolActivity
    var showsProgress = true
    @State private var isExpanded = false
    @State private var selectedImageID: String?

    private var previews: [ToolImagePreview] {
        guard !activity.isRunning, !activity.isError else { return [] }
        return model.toolImagePreviews.previews(for: activity.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if previews.isEmpty {
                titleRow.accessibilityElement(children: .combine)
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: { titleRow.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityValue(chatText(isExpanded ? "chat.activity.expanded" : "chat.activity.collapsed"))
                    .accessibilityIdentifier("toolActivityDisclosureButton")
                if isExpanded {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(previews) { preview in
                                Button { selectedImageID = preview.id } label: {
                                    Image(uiImage: preview.image).resizable().scaledToFit()
                                        .frame(width: 104, height: 112)
                                        .background(Color(uiColor: .secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(chatText("chat.activity.openImage"))
                                .accessibilityIdentifier("toolActivityImageThumbnail")
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolActivityRow")
        .sheet(isPresented: Binding(get: { selectedImageID != nil }, set: { if !$0 { selectedImageID = nil } })) {
            if let preview = previews.first(where: { $0.id == selectedImageID }) {
                ToolImageViewer(image: preview.image)
            }
        }
        .onChange(of: previews.map(\.id)) { _, ids in
            if ids.isEmpty { isExpanded = false }
            if let selectedImageID, !ids.contains(selectedImageID) { self.selectedImageID = nil }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if activity.isRunning && showsProgress {
                ProgressView().controlSize(.small).frame(width: 20)
            } else {
                Image(systemName: activity.isError ? "exclamationmark.circle" : symbol)
                    .frame(width: 20).accessibilityHidden(true)
            }
            Text(DeviceToolPresentation.activityTitle(for: activity))
                .fixedSize(horizontal: false, vertical: true)
            if !previews.isEmpty {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.medium)).accessibilityHidden(true)
            }
        }
    }
    private var symbol: String {
        switch activity.name {
        case "device_screenshot": "photo.on.rectangle.angled"
        case "device_list_apps", "device_launch_app": "app"
        case "device_tap": "hand.tap"
        case "device_swipe": "hand.draw"
        case "device_type_text", "device_press_key": "keyboard"
        case "device_home": "house"
        default: "sparkle"
        }
    }
}

struct AssistantReplyIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animates = false
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle().fill(.secondary).frame(width: 5, height: 5)
                        .opacity(reduceMotion || animates ? 0.8 : 0.25)
                        .offset(y: reduceMotion || !animates ? 0 : -3)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever().delay(Double(index) * 0.16), value: animates)
                }
            }
            Text(chatText("chat.replying")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8).onAppear { animates = true }
        .accessibilityElement(children: .combine).accessibilityIdentifier("assistantReplyIndicator")
    }
}
