import EiscueAgentKit
import SwiftUI
import UIKit

struct ChatMessageRow: View {
    @Environment(AppModel.self) private var model
    let message: AgentMessage
    @State private var showsSelection = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 42) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    if message.role == .assistant { AssistantMessageContent(text: message.text).equatable() }
                    else if !message.text.isEmpty { Text(verbatim: message.text).textSelection(.enabled) }
                    ForEach(message.attachments) { attachment in ChatAttachmentView(attachment: attachment) }
                    if model.unsubmittedMessageIDs.contains(message.id) {
                        Text("assistant.unsubmittedMessage").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, message.role == .user ? 16 : 0)
                .padding(.vertical, message.role == .user ? 12 : 4)
                .background(message.role == .user ? Color.primary.opacity(0.07) : .clear,
                            in: RoundedRectangle(cornerRadius: 22))
                .contextMenu { messageMenu }
                .accessibilityElement(children: .contain).accessibilityIdentifier("messageBubble")
                HStack(spacing: 16) {
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption2.monospacedDigit()).accessibilityIdentifier("messageTime")
                    Button { copy() } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc").frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .accessibilityLabel(chatText(didCopy ? "chat.copied" : "chat.copy"))
                    .accessibilityIdentifier(message.role == .user ? "userCopyMessageButton" : "copyMessageButton")
                    ShareLink(item: message.text) {
                        Image(systemName: "square.and.arrow.up").frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .accessibilityLabel(chatText("chat.share"))
                    .accessibilityIdentifier(message.role == .user ? "userShareMessageButton" : "shareMessageButton")
                    Menu { messageMenu } label: {
                        Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .accessibilityLabel(chatText("chat.more"))
                    .accessibilityIdentifier(message.role == .user ? "userMessageMoreButton" : "messageMoreButton")
                }
                .font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
                .padding(.horizontal, message.role == .user ? 8 : 0)
            }
            if message.role != .user { Spacer(minLength: 0) }
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
    }

    @ViewBuilder private var messageMenu: some View {
        Button(chatText("chat.copy"), systemImage: "doc.on.doc") { copy() }
        Button(chatText("chat.selectText"), systemImage: "selection.pin.in.out") { showsSelection = true }
            .accessibilityIdentifier("selectMessageTextButton")
        ShareLink(item: message.text) { Label(chatText("chat.share"), systemImage: "square.and.arrow.up") }
        if message.role == .user {
            Button(chatText("chat.useAsDraft"), systemImage: "pencil") { model.draft = message.text }
                .disabled(model.isBusy)
        }
        NavigationLink { RunHistoryView(conversationID: model.selectedConversationID) } label: {
            Label("runs.conversationTitle", systemImage: "clock.arrow.circlepath")
        }.accessibilityIdentifier("messageRunHistoryButton")
    }

    private func copy() {
        UIPasteboard.general.string = message.text
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
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
    let activity: ToolActivity
    @State private var isExpanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if !activity.arguments.isEmpty {
                    detail(chatText("chat.toolInput"), text: activity.arguments)
                }
                if !activity.output.isEmpty { detail(chatText("chat.toolOutput"), text: activity.output) }
            }.padding(.vertical, 8)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if activity.isRunning { ProgressView().controlSize(.small).frame(width: 20) }
                else { Image(systemName: activity.isError ? "exclamationmark.circle" : symbol).frame(width: 20) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    if let summary { Text(summary).font(.caption.monospaced()).lineLimit(2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Text(activity.startedAt, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }.padding(.vertical, 4)
        }
        .tint(.secondary).padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("toolActivityRow")
    }
    private func detail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(verbatim: text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }.scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
    private var title: String {
        switch activity.name {
        case "device_screenshot": String(localized: "scope.observe")
        case "device_list_apps": String(localized: "tool.listApps")
        case "device_tap": String(localized: "tool.tap")
        case "device_swipe": String(localized: "tool.swipe")
        case "device_type_text": String(localized: "tool.typeText")
        case "device_launch_app": String(localized: "tool.launchApp")
        case "device_home": String(localized: "tool.home")
        default: activity.name
        }
    }
    private var symbol: String {
        switch activity.name {
        case "device_screenshot": "viewfinder"
        case "device_list_apps", "device_launch_app": "app"
        case "device_tap", "device_swipe": "hand.tap"
        case "device_type_text": "keyboard"
        case "device_home": "house"
        default: "terminal"
        }
    }
    private var summary: String? {
        guard let data = activity.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["command", "path", "bundle_id", "text"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
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
