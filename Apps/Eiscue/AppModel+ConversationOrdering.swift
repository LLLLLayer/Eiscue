import EiscueAgentKit
import Foundation

enum ConversationMoveDirection: Int {
    case up = -1
    case down = 1
}

/// A manual order is independent of message timestamps, so a new reply cannot
/// undo the user's arrangement. Newly created chats start above unpinned chats.
struct ConversationOrdering {
    private(set) var orderedIDs: [UUID]
    private(set) var pinnedIDs: Set<UUID>

    init(orderedIDs: [UUID] = [], pinnedIDs: Set<UUID> = []) {
        self.orderedIDs = orderedIDs
        self.pinnedIDs = pinnedIDs
    }

    init(preferences: UserDefaults) {
        orderedIDs = (preferences.stringArray(forKey: "conversationOrder") ?? []).compactMap(UUID.init(uuidString:))
        pinnedIDs = Set((preferences.stringArray(forKey: "pinnedConversations") ?? []).compactMap(UUID.init(uuidString:)))
    }

    func save(to preferences: UserDefaults) {
        preferences.set(orderedIDs.map(\.uuidString), forKey: "conversationOrder")
        preferences.set(pinnedIDs.map(\.uuidString).sorted(), forKey: "pinnedConversations")
    }

    func sorted(_ conversations: [Conversation]) -> [Conversation] {
        let byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return resolvedIDs(for: conversations).compactMap { byID[$0] }
    }

    func canMove(_ id: UUID, direction: ConversationMoveDirection, in conversations: [Conversation]) -> Bool {
        let ids = resolvedIDs(for: conversations)
        guard let index = ids.firstIndex(of: id) else { return false }
        let target = index + direction.rawValue
        return ids.indices.contains(target) && pinnedIDs.contains(id) == pinnedIDs.contains(ids[target])
    }

    mutating func move(_ id: UUID, direction: ConversationMoveDirection, in conversations: [Conversation]) {
        guard canMove(id, direction: direction, in: conversations) else { return }
        normalize(conversations)
        guard let index = orderedIDs.firstIndex(of: id) else { return }
        orderedIDs.swapAt(index, index + direction.rawValue)
    }

    mutating func togglePin(_ id: UUID, in conversations: [Conversation]) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        normalize(conversations)
        orderedIDs.removeAll { $0 == id }
        if pinnedIDs.remove(id) != nil {
            let firstUnpinned = orderedIDs.firstIndex { !pinnedIDs.contains($0) } ?? orderedIDs.endIndex
            orderedIDs.insert(id, at: firstUnpinned)
        } else {
            pinnedIDs.insert(id)
            orderedIDs.insert(id, at: 0)
        }
    }

    private func resolvedIDs(for conversations: [Conversation]) -> [UUID] {
        let available = Set(conversations.map(\.id))
        var seen = Set<UUID>()
        let saved = orderedIDs.filter { available.contains($0) && seen.insert($0).inserted }
        let new = conversations.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }.map(\.id).filter { seen.insert($0).inserted }
        let combined = new + saved
        return combined.filter { pinnedIDs.contains($0) } + combined.filter { !pinnedIDs.contains($0) }
    }

    private mutating func normalize(_ conversations: [Conversation]) {
        orderedIDs = resolvedIDs(for: conversations)
        pinnedIDs.formIntersection(conversations.map(\.id))
    }
}

/// Resolve the list once per content/order change. Row menus otherwise sort the
/// entire history twice per row and repeatedly decode the same preferences.
struct ConversationSidebarCache {
    let contentRevision: Int
    let orderRevision: Int
    let items: [Conversation]
    let canMoveUp: Set<UUID>
    let canMoveDown: Set<UUID>

    init(contentRevision: Int, orderRevision: Int, ordering: ConversationOrdering, conversations: [Conversation]) {
        self.contentRevision = contentRevision; self.orderRevision = orderRevision
        items = ordering.sorted(conversations)
        var up = Set<UUID>(), down = Set<UUID>()
        for index in items.indices.dropFirst() {
            let previous = items[index - 1].id, current = items[index].id
            if ordering.pinnedIDs.contains(previous) == ordering.pinnedIDs.contains(current) {
                up.insert(current); down.insert(previous)
            }
        }
        canMoveUp = up; canMoveDown = down
    }
}

extension AppModel {
    private var conversationOrdering: ConversationOrdering {
        // UserDefaults is not observable; this revision invalidates views after
        // a pin or order change even when the conversation content is unchanged.
        let revision = conversationOrderRevision
        if let cached = conversationOrderingCache, cached.revision == revision { return cached.value }
        let value = ConversationOrdering(preferences: preferences)
        conversationOrderingCache = (revision, value)
        return value
    }

    private var conversationSidebar: ConversationSidebarCache {
        let content = conversationListRevision, order = conversationOrderRevision
        if let cached = conversationSidebarCache, cached.contentRevision == content, cached.orderRevision == order { return cached }
        let value = ConversationSidebarCache(contentRevision: content, orderRevision: order,
            ordering: conversationOrdering, conversations: conversations)
        conversationSidebarCache = value
        return value
    }

    var sortedConversations: [Conversation] { conversationSidebar.items }

    func isConversationPinned(_ id: UUID) -> Bool { conversationOrdering.pinnedIDs.contains(id) }

    func canMoveConversation(_ id: UUID, direction: ConversationMoveDirection) -> Bool {
        let projection = conversationSidebar
        return (direction == .up ? projection.canMoveUp : projection.canMoveDown).contains(id)
    }

    func moveConversation(_ id: UUID, direction: ConversationMoveDirection) {
        guard !isBusy else { return }
        var ordering = conversationOrdering
        ordering.move(id, direction: direction, in: conversations)
        ordering.save(to: preferences)
        conversationOrderRevision += 1
    }

    func toggleConversationPinned(_ id: UUID) {
        guard !isBusy else { return }
        var ordering = conversationOrdering
        ordering.togglePin(id, in: conversations)
        ordering.save(to: preferences)
        conversationOrderRevision += 1
    }

    func setConversationsPinned(_ ids: Set<UUID>, pinned: Bool) {
        guard !isBusy else { return }
        var ordering = conversationOrdering
        // Inserting at the front in reverse order keeps the selected rows' order.
        for conversation in ordering.sorted(conversations).reversed()
            where ids.contains(conversation.id) && ordering.pinnedIDs.contains(conversation.id) != pinned {
            ordering.togglePin(conversation.id, in: conversations)
        }
        ordering.save(to: preferences)
        conversationOrderRevision += 1
    }

    func renameConversation(_ id: UUID, title: String) async {
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !isBusy, !name.isEmpty,
              var conversation = conversations.first(where: { $0.id == id }), conversation.title != name else { return }
        isSaving = true; defer { isSaving = false }
        conversation.title = name
        do {
            try await repository.save(conversation)
            if let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index] = conversation }
        } catch {
            errorMessage = String(format: String(localized: "sidebar.renameFailed", table: "Navigation"), safeError(error))
        }
    }
}
