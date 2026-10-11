import EiscueAgentKit
import SwiftUI

struct ConversationSidebarView: View {
    @Environment(AppModel.self) private var model
    let selectConversation: (Conversation) -> Void
    let newConversation: () -> Void
    let openSettings: () -> Void
    var closeSidebar: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("sidebar.title", tableName: "Navigation")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let closeSidebar {
                    Button(action: closeSidebar) {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .foregroundStyle(EiscueStyle.accent)
                    .accessibilityLabel(Text("sidebar.close", tableName: "Navigation"))
                    .accessibilityIdentifier("closeSidebarButton")
                }
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 20)

            if model.conversations.isEmpty {
                VStack(spacing: 10) {
                    Image("StickerRest")
                        .resizable().scaledToFit().frame(height: 120)
                        .accessibilityHidden(true)
                    Text("sidebar.empty", tableName: "Navigation")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.sortedConversations) { conversation in
                        conversationRow(conversation)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 12) {
                    Button(action: newConversation) {
                        Label {
                            Text("sidebar.newConversation", tableName: "Navigation")
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        } icon: {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(EiscueStyle.accent)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("newConversationButton")
                    Spacer(minLength: 0)
                    Button(action: openSettings) {
                        Image(systemName: "gearshape")
                            .foregroundStyle(EiscueStyle.accent)
                    }
                    .buttonStyle(.glass(.clear))
                    .buttonBorderShape(.circle)
                    .fixedSize()
                    .accessibilityLabel(Text("sidebar.settings", tableName: "Navigation"))
                    .accessibilityIdentifier("sidebarSettingsButton")
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(EiscueStyle.background)
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        let selected = model.selectedConversationID == conversation.id
        let pinned = model.isConversationPinned(conversation.id)
        return Button {
            selectConversation(conversation)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left")
                    .foregroundStyle(EiscueStyle.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(conversation.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(EiscueStyle.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(selected ? EiscueStyle.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityIdentifier("conversationRow_\(conversation.id.uuidString)")
        .accessibilityLabel(Text(conversation.title))
        .accessibilityValue(pinned ? String(localized: "sidebar.pinned", table: "Navigation") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button {
                model.toggleConversationPinned(conversation.id)
            } label: {
                Label(pinned ? String(localized: "sidebar.unpin", table: "Navigation") : String(localized: "sidebar.pin", table: "Navigation"),
                      systemImage: pinned ? "pin.slash" : "pin")
            }
            .accessibilityIdentifier("pinConversationButton")
            Button {
                model.moveConversation(conversation.id, direction: .up)
            } label: {
                Label(String(localized: "sidebar.moveUp", table: "Navigation"), systemImage: "arrow.up")
            }
            .disabled(!model.canMoveConversation(conversation.id, direction: .up))
            .accessibilityIdentifier("moveConversationUpButton")
            Button {
                model.moveConversation(conversation.id, direction: .down)
            } label: {
                Label(String(localized: "sidebar.moveDown", table: "Navigation"), systemImage: "arrow.down")
            }
            .disabled(!model.canMoveConversation(conversation.id, direction: .down))
            .accessibilityIdentifier("moveConversationDownButton")
            Button(role: .destructive) {
                Task { await model.delete(conversation) }
            } label: {
                Label(String(localized: "sidebar.delete", table: "Navigation"), systemImage: "trash")
            }
            .accessibilityIdentifier("deleteConversationButton")
        }
    }
}
