import EiscueAgentKit
import UIKit
import XCTest
@testable import Eiscue

@MainActor
final class ToolImagePreviewStoreTests: XCTestCase {
    func testEachActivityKeepsItsOwnReturnedImageAcrossCallsAndRuns() throws {
        let store = ToolImagePreviewStore()
        let conversationID = UUID()
        store.record(completion(.image(image(width: 40), mimeType: "image/png")), activityID: "run-1:call", conversationID: conversationID)
        store.record(completion(.image(image(width: 80), mimeType: "image/png"), name: "device_tap"), activityID: "run-2:call", conversationID: conversationID)
        let first = try XCTUnwrap(store.previews(for: "run-1:call").first)
        let second = try XCTUnwrap(store.previews(for: "run-2:call").first)
        XCTAssertEqual(first.image.size.width, 40)
        XCTAssertEqual(second.image.size.width, 80)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(store.previews(for: "unknown:call").isEmpty)
    }

    func testOnlySuccessfulKnownDeviceResultsWithDecodableImagesCanExpand() {
        let store = ToolImagePreviewStore()
        let conversationID = UUID()
        let content: [AgentToolContent] = [.text("Actual result"), .image(data: image(), mimeType: "image/png")]
        let cases: [(String, AgentToolResult)] = [
            ("device_screenshot", .text("frameId=metadata-only")),
            ("device_screenshot", .init(content: content, isError: true)),
            ("device_screenshot", .image(Data([0, 1, 2]), mimeType: "image/png")),
            ("device_screenshot", .image(image(), mimeType: "text/plain")),
            ("device_list_apps", .init(content: content)),
            ("unrecognized_tool", .init(content: content))
        ]
        for (name, result) in cases {
            store.record(completion(.init(content: content)), activityID: "call", conversationID: conversationID)
            XCTAssertEqual(store.previews(for: "call").count, 1)
            store.record(completion(result, name: name), activityID: "call", conversationID: conversationID)
            XCTAssertTrue(store.previews(for: "call").isEmpty, "\(name) must not retain a stale or fabricated preview.")
        }
        XCTAssertEqual(store.imageCount, 0)
        XCTAssertEqual(store.byteCount, 0)
    }

    func testCountAndDecodedByteLimitsEvictOldestImages() throws {
        let result = completion(.image(image(), mimeType: "image/png"))
        let conversationID = UUID()
        let measured = ToolImagePreviewStore()
        measured.record(result, activityID: "measure", conversationID: conversationID)
        let bytes = measured.byteCount
        XCTAssertGreaterThan(bytes, 0)
        for store in [ToolImagePreviewStore(maximumImageCount: 2),
                      ToolImagePreviewStore(maximumByteCount: bytes * 2)] {
            for index in 0..<3 { store.record(result, activityID: "\(index)", conversationID: conversationID) }
            XCTAssertTrue(store.previews(for: "0").isEmpty)
            XCTAssertEqual(store.previews(for: "1").count, 1)
            XCTAssertEqual(store.previews(for: "2").count, 1)
            XCTAssertEqual(store.imageCount, 2)
            XCTAssertEqual(store.byteCount, bytes * 2)
            store.removeAll()
            XCTAssertTrue(store.previews(for: "2").isEmpty)
            XCTAssertEqual(store.imageCount, 0); XCTAssertEqual(store.byteCount, 0)
        }
        let tooSmall = ToolImagePreviewStore(maximumByteCount: bytes - 1)
        tooSmall.record(result, activityID: "oversized", conversationID: conversationID)
        XCTAssertTrue(tooSmall.previews(for: "oversized").isEmpty)
    }

    func testDecodedImagesHaveBoundedDimensionsAndNoMoreThanFourPerActivity() throws {
        let store = ToolImagePreviewStore()
        let content: [AgentToolContent] = Array(repeating: .image(data: image(width: 3_200), mimeType: "image/png"), count: 5)
        store.record(completion(.init(content: content)), activityID: "call", conversationID: UUID())
        let previews = store.previews(for: "call")
        XCTAssertEqual(previews.count, 4)
        XCTAssertEqual(Set(previews.map(\.id)).count, 4)
        for preview in previews {
            XCTAssertEqual(preview.image.size.width, 1_600)
            XCTAssertLessThanOrEqual(preview.image.size.height, 1_600)
        }
    }

    func testDeletingConversationClearsOnlyItsMemoryPreviewsWithoutPersistingImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ToolImagePreviewStoreTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageDirectory: directory, preferences: preferences)
        let deleted = Conversation(title: "Delete")
        let kept = Conversation(title: "Keep")
        model.conversations = [deleted, kept]
        let result = completion(.image(image(), mimeType: "image/png"))
        model.toolImagePreviews.record(result, activityID: "delete-1", conversationID: deleted.id)
        model.toolImagePreviews.record(result, activityID: "keep", conversationID: kept.id)
        model.toolImagePreviews.record(result, activityID: "delete-2", conversationID: deleted.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Preview recording must not create files.")
        await model.delete(deleted)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.toolImagePreviews.previews(for: "delete-1").isEmpty)
        XCTAssertTrue(model.toolImagePreviews.previews(for: "delete-2").isEmpty)
        XCTAssertEqual(model.toolImagePreviews.previews(for: "keep").count, 1)
        XCTAssertEqual(model.conversations.map(\.id), [kept.id])
    }

    private func completion(_ result: AgentToolResult, name: String = "device_screenshot") -> AgentToolCompletion {
        AgentToolCompletion(call: AgentToolCall(id: "call", name: name, arguments: [:]), result: result)
    }

    private func image(width: Int = 40) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: width, height: 80)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.gray.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
