import EiscueAgentKit
import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Eiscue

@MainActor final class MessageSharingTests: XCTestCase {
    private var directory: URL!
    private var originals: URL { directory.appendingPathComponent("Attachments", isDirectory: true) }
    private var exports: URL { directory.appendingPathComponent("Exports", isDirectory: true) }

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try await super.tearDown()
    }

    func testTextOnlySharesTextAndDoesNotCreateExportFiles() async throws {
        let store = MessageAttachments(directory: originals)
        let payload = try await store.prepareShare(AgentMessage(role: .user, text: "Actual message text"), exportRoot: exports)
        defer { payload.cleanup() }
        XCTAssertEqual(payload.text, "Actual message text")
        XCTAssertTrue(payload.files.isEmpty)
        XCTAssertNil(payload.directory)
        XCTAssertEqual(payload.activityItems().first as? String, "Actual message text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
    }

    func testEmptyMessageCannotProduceEmptyStringShare() async throws {
        let store = MessageAttachments(directory: originals)
        do {
            _ = try await store.prepareShare(AgentMessage(role: .user, text: " \n\t "), exportRoot: exports)
            XCTFail("An empty message must not open the native share UI")
        } catch { guard case MessageSharingError.empty = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
    }

    func testPDFOnlySharesActualSavedPDFBytesAfterStoreReload() async throws {
        let bytes = pdf()
        let store = MessageAttachments(directory: originals)
        let attachment = try await store.importData(bytes, name: "旅行计划.pdf", type: .pdf)
        let reloaded = MessageAttachments(directory: originals)
        let message = AgentMessage(role: .user, text: "", attachments: [attachment])
        let canShare = await reloaded.canShareAttachments(message.attachments)
        XCTAssertTrue(canShare)
        let payload = try await reloaded.prepareShare(message, exportRoot: exports)
        defer { payload.cleanup() }
        XCTAssertNil(payload.text)
        XCTAssertEqual(payload.files.count, 1)
        let file = try XCTUnwrap(payload.files.first)
        XCTAssertEqual(file.url.lastPathComponent, "旅行计划.pdf")
        XCTAssertEqual(file.typeIdentifier, UTType.pdf.identifier)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: file.url)).pageCount, 1)
        let activity = UIActivityViewController(activityItems: payload.activityItems(), applicationActivities: nil)
        let source = try XCTUnwrap(payload.activityItems().first as? MessageSharedFileSource)
        XCTAssertEqual(source.activityViewControllerPlaceholderItem(activity) as? URL, file.url)
        XCTAssertEqual(source.activityViewController(activity, itemForActivityType: nil) as? URL, file.url)
        XCTAssertEqual(source.activityViewController(activity, dataTypeIdentifierForActivityType: nil), UTType.pdf.identifier)
    }

    func testTextFilePreservesOriginalUTF16EncodingAndHumanFilename() async throws {
        let bytes = try XCTUnwrap("Hello，世界".data(using: .utf16))
        let store = MessageAttachments(directory: originals)
        let attachment = try await store.importData(bytes, name: "Meeting notes.txt", type: .plainText)
        let payload = try await store.prepareShare(AgentMessage(role: .user, text: "", attachments: [attachment]), exportRoot: exports)
        defer { payload.cleanup() }
        let file = try XCTUnwrap(payload.files.first)
        XCTAssertEqual(file.url.lastPathComponent, "Meeting notes.txt")
        XCTAssertEqual(file.typeIdentifier, UTType.plainText.identifier)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    func testPhotoOnlySharesRealNormalizedJPEGWithMatchingExtension() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let store = MessageAttachments(directory: originals)
        let attachment = try await store.importData(XCTUnwrap(image.pngData()), name: "Ice photo.png", type: .png)
        let payload = try await store.prepareShare(AgentMessage(role: .user, text: "", attachments: [attachment]), exportRoot: exports)
        defer { payload.cleanup() }
        XCTAssertNil(payload.text)
        let file = try XCTUnwrap(payload.files.first)
        XCTAssertEqual(file.typeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(UTType(filenameExtension: file.url.pathExtension), .jpeg)
        XCTAssertTrue(file.url.lastPathComponent.hasPrefix("Ice photo."))
        let bytes = try Data(contentsOf: file.url)
        XCTAssertEqual(bytes, attachment.imageData)
        XCTAssertNotNil(UIImage(data: bytes))
        XCTAssertTrue(bytes.starts(with: [0xff, 0xd8]))
    }

    func testMixedTextAndFilesIncludesAllActualPayloadItemsAndDuplicateNames() async throws {
        let store = MessageAttachments(directory: originals)
        let first = try await store.importData(Data("first file".utf8), name: "notes.txt", type: .plainText)
        let second = try await store.importData(Data("second file".utf8), name: "notes.txt", type: .plainText)
        let payload = try await store.prepareShare(AgentMessage(role: .user, text: "Read these files", attachments: [first, second]), exportRoot: exports)
        defer { payload.cleanup() }
        XCTAssertEqual(payload.text, "Read these files")
        XCTAssertEqual(payload.activityItems().count, 3)
        XCTAssertEqual(payload.activityItems().first as? String, "Read these files")
        XCTAssertEqual(payload.files.map { $0.url.lastPathComponent }, ["notes.txt", "notes.txt"])
        XCTAssertNotEqual(payload.files[0].url, payload.files[1].url)
        XCTAssertEqual(try Data(contentsOf: payload.files[0].url), Data("first file".utf8))
        XCTAssertEqual(try Data(contentsOf: payload.files[1].url), Data("second file".utf8))
    }

    func testMissingOriginalRejectsEntireMixedMessageInsteadOfSilentlySharingOnlyText() async throws {
        let store = MessageAttachments(directory: originals)
        let attachment = try await store.importData(pdf(), name: "missing.pdf", type: .pdf)
        try FileManager.default.removeItem(at: originals.appendingPathComponent(attachment.id.uuidString).appendingPathExtension("source"))
        let canShare = await store.canShareAttachments([attachment])
        XCTAssertFalse(canShare)
        do {
            _ = try await store.prepareShare(AgentMessage(role: .user, text: "This must include the PDF", attachments: [attachment]), exportRoot: exports)
            XCTFail("Must not claim success while dropping a missing attachment")
        } catch { guard case MessageSharingError.unavailable = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
    }

    func testLegacyPDFCannotBeExportedAsFakePDFButRetainedTextCanBeShared() async throws {
        let store = MessageAttachments(directory: originals)
        let pdf = AgentAttachment(name: "old.pdf", mimeType: "application/pdf", content: .text("Extracted PDF text"))
        let canSharePDF = await store.canShareAttachments([pdf])
        XCTAssertFalse(canSharePDF)
        let text = AgentAttachment(name: "old.txt", mimeType: "text/plain", content: .text("Retained legacy text"))
        let payload = try await store.prepareShare(AgentMessage(role: .user, text: "", attachments: [text]), exportRoot: exports)
        defer { payload.cleanup() }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(payload.files.first).url), Data("Retained legacy text".utf8))
    }

    func testExportCleanupIsIdempotentAndNeverDeletesSavedOriginals() async throws {
        let store = MessageAttachments(directory: originals)
        let attachment = try await store.importData(Data("Keep the original".utf8), name: "keep.txt", type: .plainText)
        let message = AgentMessage(role: .user, text: "", attachments: [attachment])
        let first = try await store.prepareShare(message, exportRoot: exports)
        let second = try await store.prepareShare(message, exportRoot: exports)
        let firstFile = try XCTUnwrap(first.files.first).url
        let secondFile = try XCTUnwrap(second.files.first).url
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))
        first.cleanup(); first.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
        let canShare = await store.canShareAttachments([attachment])
        XCTAssertTrue(canShare)
        await store.remove(attachment.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.appendingPathComponent(attachment.id.uuidString).appendingPathExtension("source").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.appendingPathComponent(attachment.id.uuidString).appendingPathExtension("source.json").path))
        XCTAssertEqual(try Data(contentsOf: secondFile), Data("Keep the original".utf8), "Deleting a conversation must not invalidate an in-flight share export")
        second.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.path))
    }

    func testFailedExportRemovesPartialFilesAndFilenameCannotEscapePrivateDirectory() throws {
        let valid = MessageShareContent(name: "../../private/key.txt", typeIdentifier: UTType.plainText.identifier, data: Data("User file bytes".utf8))
        let payload = try MessageSharing.prepare(text: "", attachments: [valid], exportRoot: exports)
        defer { payload.cleanup() }
        let file = try XCTUnwrap(payload.files.first)
        XCTAssertEqual(file.url.deletingLastPathComponent().deletingLastPathComponent(), payload.directory)
        XCTAssertFalse(file.url.lastPathComponent.contains("/"))
        XCTAssertEqual(try Data(contentsOf: file.url), valid.data)
        let invalid = MessageShareContent(name: "empty.txt", typeIdentifier: UTType.plainText.identifier, data: Data())
        XCTAssertThrowsError(try MessageSharing.prepare(text: "", attachments: [valid, invalid], exportRoot: exports))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exports.path).count, 1, "A failed export must not leave a second partial session")
    }

    func testDismantledPresenterCleansPendingExportWithoutDeletingSavedAttachment() async throws {
        let store = MessageAttachments(directory: originals)
        let attachment = try await store.importData(Data("Presenter lifetime".utf8), name: "lifetime.txt", type: .plainText)
        let payload = try await store.prepareShare(AgentMessage(role: .user, text: "", attachments: [attachment]), exportRoot: exports)
        let host = MessageShareHost()
        host.loadViewIfNeeded()
        var completed: [(UUID, Bool)] = []
        host.finished = { completed.append(($0, $1)) }
        host.prepare(payload) // No window: wait instead of presenting globally.
        XCTAssertNil(host.presentedViewController)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(payload.files.first).url.path))
        host.cancel(); host.cancel()
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0, payload.id)
        XCTAssertEqual(completed.first?.1, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(payload.directory).path))
        let canShare = await store.canShareAttachments([attachment])
        XCTAssertTrue(canShare)
    }

    func testNativeShareCompletionCanArriveFromBackgroundQueue() async {
        for hasError in [false, true] {
            let received = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let callback = MessageShareCallbacks.completion { value in
                    MainActor.assertIsolated()
                    continuation.resume(returning: value)
                }
                DispatchQueue.global().async {
                    // Raw returned objects are never sent across to MainActor.
                    callback(nil, true, [NSObject()], hasError ? NSError(domain: "Fixture", code: 1) : nil)
                }
            }
            XCTAssertEqual(received, hasError)
        }
    }

    private func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 100)).pdfData { context in
            context.beginPage()
            ("Actual PDF document" as NSString).draw(at: CGPoint(x: 12, y: 12), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
    }
}
