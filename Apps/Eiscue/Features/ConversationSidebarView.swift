import EiscueAgentKit
import SwiftUI

struct ConversationSidebarView: View {
    @Environment(AppModel.self) private var model
    let selectConversation: (Conversation) -> Void
    let newConversation: () -> Void
    let openSettings: () -> Void
    var closeSidebar: (() -> Void)?
    @State private var isSelecting = false
    @State private var selectedIDs = Set<UUID>()
    @State private var deleteIDs = Set<UUID>()
    @State private var confirmsDelete = false
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var showsRename = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isSelecting ? String(format: text("sidebar.selectedCount"), selectedIDs.count) : text("sidebar.title"))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isSelecting {
                    Button("common.done") {
                        isSelecting = false; selectedIDs.removeAll()
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.glass)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("doneSelectingConversationsButton")
                }
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
                if isSelecting {
                    HStack {
                        Button(allSelected ? text("sidebar.deselectAll") : text("sidebar.selectAll")) {
                            selectedIDs = allSelected ? [] : Set(model.conversations.map(\.id))
                        }
                        .font(.subheadline).disabled(model.isBusy)
                        .accessibilityIdentifier("selectAllConversationsButton")
                        Spacer()
                    }.padding(.horizontal, 24).padding(.vertical, 8)
                }
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

            if isSelecting {
                selectionActions
            } else {
                footer
            }
        }
        .background(EiscueStyle.background)
        .onChange(of: model.conversations.map(\.id)) { _, ids in
            selectedIDs.formIntersection(ids)
            if ids.isEmpty { isSelecting = false }
        }
        .alert(text("sidebar.rename"), isPresented: $showsRename) {
            TextField(text("sidebar.name"), text: $renameTitle)
                .accessibilityIdentifier("conversationNameInput")
            Button("common.cancel", role: .cancel) { renameID = nil }
            Button(text("sidebar.saveName")) {
                guard let id = renameID else { return }
                let title = renameTitle
                renameID = nil
                Task { await model.renameConversation(id, title: title) }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            .accessibilityIdentifier("saveConversationNameButton")
        }
        .confirmationDialog(text("sidebar.deleteConfirm"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(String(format: text("sidebar.deleteCount"), deleteIDs.count), role: .destructive) {
                let ids = deleteIDs
                Task {
                    await model.deleteConversations(ids)
                    selectedIDs.formIntersection(model.conversations.map(\.id))
                    if selectedIDs.isEmpty { isSelecting = false }
                }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("confirmDeleteConversationsButton")
            Button("common.cancel", role: .cancel) { deleteIDs.removeAll() }
        } message: {
            Text("sidebar.deleteDetail", tableName: "Navigation")
        }
    }

    private var footer: some View {
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
                    .frame(minHeight: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(model.isBusy)
                .accessibilityIdentifier("newConversationButton")
                Spacer(minLength: 0)
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(EiscueStyle.accent)
                        .frame(minWidth: 24, minHeight: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("sidebar.settings", tableName: "Navigation"))
                .accessibilityIdentifier("sidebarSettingsButton")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var selectionActions: some View {
        GlassEffectContainer(spacing: 16) {
            HStack {
                Button {
                    model.setConversationsPinned(selectedIDs, pinned: !allSelectedPinned)
                } label: {
                    Label(allSelectedPinned ? text("sidebar.unpin") : text("sidebar.pin"),
                          systemImage: allSelectedPinned ? "pin.slash" : "pin")
                }
                .accessibilityIdentifier("pinSelectedConversationsButton")
                Spacer(minLength: 12)
                Button {
                    deleteIDs = selectedIDs; confirmsDelete = true
                } label: {
                    Label(String(localized: "common.delete"), systemImage: "trash")
                }
                .accessibilityIdentifier("deleteSelectedConversationsButton")
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
            .disabled(selectedIDs.isEmpty || model.isBusy)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        let selected = model.selectedConversationID == conversation.id
        let checked = selectedIDs.contains(conversation.id)
        let pinned = model.isConversationPinned(conversation.id)
        return Button {
            if isSelecting {
                if checked { selectedIDs.remove(conversation.id) }
                else { selectedIDs.insert(conversation.id) }
            } else { selectConversation(conversation) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelecting ? (checked ? "checkmark.circle.fill" : "circle") : "bubble.left")
                    .foregroundStyle(EiscueStyle.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(String(format: text("sidebar.updatedAt"), conversation.updatedAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("conversationUpdatedAt_\(conversation.id.uuidString)")
                }
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
            .background((isSelecting ? checked : selected) ? EiscueStyle.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversationRow_\(conversation.id.uuidString)")
        .accessibilityLabel(Text(conversation.title))
        .accessibilityValue(pinned ? String(localized: "sidebar.pinned", table: "Navigation") : "")
        .accessibilityAddTraits((isSelecting ? checked : selected) ? .isSelected : [])
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if !isSelecting {
                Button {
                    renameID = conversation.id; renameTitle = conversation.title; showsRename = true
                } label: {
                    Label(text("sidebar.rename"), systemImage: "pencil")
                }
                .accessibilityIdentifier("renameConversationButton")
                Button {
                    isSelecting = true; selectedIDs = [conversation.id]
                } label: {
                    Label(text("sidebar.select"), systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("selectConversationButton")
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
                    deleteIDs = [conversation.id]; confirmsDelete = true
                } label: {
                    Label(String(localized: "sidebar.delete", table: "Navigation"), systemImage: "trash")
                }
                .accessibilityIdentifier("deleteConversationButton")
            }
        }
    }

    private var allSelected: Bool { selectedIDs.count == model.conversations.count }
    private var allSelectedPinned: Bool { !selectedIDs.isEmpty && selectedIDs.allSatisfy(model.isConversationPinned) }
    private func text(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Navigation") }
}
