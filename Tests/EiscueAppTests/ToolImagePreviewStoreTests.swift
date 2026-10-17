import EiscueAgentKit
import UIKit
import XCTest
@testable import Eiscue

@MainActor
final class ToolImagePreviewStoreTests: XCTestCase {
    func testEvictedPreviewCanReloadAndUnavailableResultsDoNotLoop() throws {
        let store = ToolImagePreviewStore(maximumImageCount: 1)
        let conversationID = UUID()
        let result = completion(.image(image(), mimeType: "image/png"))
        store.record(result, activityID: "first", conversationID: conversationID)
        store.record(result, activityID: "second", conversationID: conversationID)
        XCTAssertEqual(store.state(for: "first"), .idle)
        let token = try XCTUnwrap(store.beginLoading(activityID: "first", conversationID: conversationID))
        XCTAssertEqual(store.state(for: "first"), .loading)
        XCTAssertNil(store.beginLoading(activityID: "first", conversationID: conversationID))
        store.finishLoading(result, activityID: "first", token: token)
        XCTAssertEqual(store.state(for: "first"), .available)
        XCTAssertEqual(store.previews(for: "first").count, 1)
        let missing = try XCTUnwrap(store.beginLoading(activityID: "missing", conversationID: conversationID))
        store.finishLoading(nil, activityID: "missing", token: missing)
        XCTAssertEqual(store.state(for: "missing"), .unavailable)
        XCTAssertNil(store.beginLoading(activityID: "missing", conversationID: conversationID))
    }

    func testLateRecoveryCannotRestoreDeletedConversationOrOverwriteANewerResult() throws {
        let store = ToolImagePreviewStore()
        let conversationID = UUID()
        let old = completion(.image(image(width: 40), mimeType: "image/png"))
        let deleted = try XCTUnwrap(store.beginLoading(activityID: "deleted", conversationID: conversationID))
        store.remove(conversationID: conversationID)
        store.finishLoading(old, activityID: "deleted", token: deleted)
        XCTAssertEqual(store.state(for: "deleted"), .idle)
        XCTAssertTrue(store.previews(for: "deleted").isEmpty)
        let stale = try XCTUnwrap(store.beginLoading(activityID: "updated", conversationID: conversationID))
        store.record(completion(.image(image(width: 80), mimeType: "image/png")), activityID: "updated", conversationID: conversationID)
        store.finishLoading(old, activityID: "updated", token: stale)
        XCTAssertEqual(store.previews(for: "updated").first?.image.size.width, 80)
        let retry = try XCTUnwrap(store.beginLoading(activityID: "retry", conversationID: conversationID))
        store.cancelLoading(activityID: "retry", token: retry)
        XCTAssertEqual(store.state(for: "retry"), .idle)
    }

    func testAppRecoveryUsesExactRunRequestAndKeepsCallIDColons() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ToolImageRecovery.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageDirectory: directory, preferences: preferences)
        let conversation = Conversation(title: "Images")
        model.conversations = [conversation]
        let requests = [UUID(), UUID()]
        model.runs = requests.map { request in
            let runID = UUID()
            return RunRecord(id: runID, conversationID: conversation.id, requestID: request, startedAt: Date(),
                             scope: .observe, model: "fixture", skill: nil, state: .completed, detail: "", events: [],
                             activities: [ToolActivity(id: "\(runID.uuidString):call:with:colons", name: "device_screenshot", endedAt: Date())])
        }
        let engine = ToolImageRecoveryEngine(conversationID: conversation.id, images: [requests[0]: image(width: 40), requests[1]: image(width: 80)])
        model.configuredAgent = AgentClient(engine: engine)
        let first = try XCTUnwrap(model.runs[0].activities?.first)
        let second = try XCTUnwrap(model.runs[1].activities?.first)
        await model.loadToolImagePreviews(for: first)
        await model.loadToolImagePreviews(for: second)
        await model.loadToolImagePreviews(for: first)
        XCTAssertEqual(model.toolImagePreviews.previews(for: first.id).first?.image.size.width, 40)
        XCTAssertEqual(model.toolImagePreviews.previews(for: second.id).first?.image.size.width, 80)
        let count = await engine.readCount
        XCTAssertEqual(count, 2)
        let orphan = ToolActivity(id: "no-run:call", name: "device_screenshot", endedAt: Date())
        await model.loadToolImagePreviews(for: orphan)
        XCTAssertEqual(model.toolImagePreviews.state(for: orphan.id), .unavailable)
        let legacy = ToolActivity(id: "legacy-call", name: "device_screenshot", endedAt: Date())
        model.runs[0].activities?.append(legacy)
        await model.loadToolImagePreviews(for: legacy)
        XCTAssertEqual(model.toolImagePreviews.state(for: legacy.id), .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

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
            ("device_screenshot", .init(content: content, outcome: .failed)),
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
        model.isLoading = false
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

/// Read-only image-result snapshot injection; it cannot execute a run.
private actor ToolImageRecoveryEngine: AgentEngine {
    let conversationID: UUID
    let images: [UUID: Data]
    private(set) var readCount = 0
    var availability: AgentAvailability { .unconfigured }
    init(conversationID: UUID, images: [UUID: Data]) { self.conversationID = conversationID; self.images = images }
    func run(request: AgentRequest) throws -> AsyncThrowingStream<AgentEvent, Error> { throw AgentError.unconfigured }
    func recover(conversationID: UUID) -> AgentRecovery { .init(messages: [], hasInterruptedRun: false) }
    func toolResult(conversationID: UUID, requestID: UUID, toolCallID: String) -> AgentToolCompletion? {
        readCount += 1
        guard conversationID == self.conversationID, toolCallID == "call:with:colons", let image = images[requestID] else { return nil }
        return .init(call: .init(id: toolCallID, name: "device_screenshot", arguments: [:]), result: .image(image, mimeType: "image/png"))
    }
    func cancel() {}
    func cancel(conversationID: UUID) {}
    func removeConversation(id: UUID) {}
}
