import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

final class ConversationOrderingTests: XCTestCase {
    private func conversation(_ title: String, time: TimeInterval) -> Conversation {
        Conversation(title: title, createdAt: Date(timeIntervalSince1970: time))
    }

    func testManualOrderSurvivesNewRepliesAndInsertsNewChatAtTop() {
        let first = conversation("First", time: 1)
        var second = conversation("Second", time: 2)
        let third = conversation("Third", time: 3)
        var ordering = ConversationOrdering()
        XCTAssertEqual(ordering.sorted([first, second]).map(\.id), [second.id, first.id])
        ordering.move(first.id, direction: .up, in: [first, second])
        second.updatedAt = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(ordering.sorted([second, first]).map(\.id), [first.id, second.id])
        XCTAssertEqual(ordering.sorted([first, second, third]).map(\.id), [third.id, first.id, second.id])
    }

    func testPinnedGroupStaysAboveNewChatsAndCannotMoveAcrossItsBoundary() {
        let first = conversation("First", time: 1)
        let second = conversation("Second", time: 2)
        let third = conversation("Third", time: 3)
        let chats = [first, second, third]
        var ordering = ConversationOrdering()
        ordering.togglePin(first.id, in: chats)
        XCTAssertEqual(ordering.sorted(chats).map(\.id), [first.id, third.id, second.id])
        XCTAssertFalse(ordering.canMove(first.id, direction: .down, in: chats))
        XCTAssertFalse(ordering.canMove(third.id, direction: .up, in: chats))
        ordering.move(second.id, direction: .up, in: chats)
        XCTAssertEqual(ordering.sorted(chats).map(\.id), [first.id, second.id, third.id])
        let newest = conversation("Newest", time: 4)
        XCTAssertEqual(ordering.sorted(chats + [newest]).map(\.id), [first.id, newest.id, second.id, third.id])
    }

    func testUnpinMovesChatToTopOfUnpinnedGroupAndPinnedChatsCanBeReordered() {
        let chats = (1...3).map { conversation("\($0)", time: TimeInterval($0)) }
        var ordering = ConversationOrdering()
        ordering.togglePin(chats[0].id, in: chats)
        ordering.togglePin(chats[1].id, in: chats)
        XCTAssertEqual(ordering.sorted(chats).map(\.id), [chats[1].id, chats[0].id, chats[2].id])
        ordering.move(chats[1].id, direction: .down, in: chats)
        XCTAssertEqual(ordering.sorted(chats).map(\.id), [chats[0].id, chats[1].id, chats[2].id])
        ordering.togglePin(chats[0].id, in: chats)
        XCTAssertEqual(ordering.sorted(chats).map(\.id), [chats[1].id, chats[0].id, chats[2].id])
    }

    func testSavedOrderAndPinsRestoreWithoutDeletedOrDuplicateRows() throws {
        let suite = "ConversationOrderingTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let chats = (1...3).map { conversation("\($0)", time: TimeInterval($0)) }
        let deleted = UUID()
        var ordering = ConversationOrdering(orderedIDs: [chats[0].id, deleted, chats[0].id, chats[1].id],
                                            pinnedIDs: [deleted, chats[1].id])
        ordering.save(to: preferences)
        ordering = ConversationOrdering(preferences: preferences)
        XCTAssertEqual(ordering.sorted(chats).map(\.id), [chats[1].id, chats[2].id, chats[0].id])
        ordering.togglePin(chats[0].id, in: chats)
        ordering.save(to: preferences)
        let restored = ConversationOrdering(preferences: preferences)
        XCTAssertEqual(restored.pinnedIDs, [chats[0].id, chats[1].id])
        XCTAssertEqual(restored.sorted(chats).map(\.id), [chats[0].id, chats[1].id, chats[2].id])
        XCTAssertEqual(restored.sorted([chats[2]]).map(\.id), [chats[2].id])
    }

    func testNavigationCatalogHasEnglishAndChineseResources() throws {
        let app = Bundle(for: AppModel.self)
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["sidebar.title", "sidebar.close", "sidebar.empty", "sidebar.newConversation", "sidebar.settings",
                        "sidebar.pinned", "sidebar.pin", "sidebar.unpin", "sidebar.moveUp", "sidebar.moveDown", "sidebar.delete"] {
                let translated = bundle.localizedString(forKey: key, value: nil, table: "Navigation")
                XCTAssertNotEqual(translated, key, "Missing \(language)/Navigation/\(key)")
                XCTAssertFalse(translated.isEmpty)
            }
        }
    }
}
