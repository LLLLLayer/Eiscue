import EiscueAgentKit
import Foundation
import PDFKit
import UIKit
import XCTest
@testable import Eiscue

@MainActor final class MessageAttachmentsTests: XCTestCase {
    func testTextImportCopiesContentAndSourceRemovalDoesNotBreakAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("notes.txt")
        try Data("Actual text from a file".utf8).write(to: source)
        let store = MessageAttachments(directory: directory.appendingPathComponent("Private"))
        let attachment = try await store.importFile(source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(attachment.content, .text("Actual text from a file"))
        let persisted = directory.appendingPathComponent("Private").appendingPathComponent(attachment.id.uuidString).appendingPathExtension("json")
        XCTAssertEqual(try JSONDecoder().decode(AgentAttachment.self, from: Data(contentsOf: persisted)), attachment)
    }

    func testImagesAreRealEncodedBytesWithBoundedDimensions() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 100)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 100))
        }
        let result = try MessageAttachments.normalizedImage(XCTUnwrap(source.pngData()))
        let decoded = try XCTUnwrap(UIImage(data: result)?.cgImage)
        XCTAssertLessThanOrEqual(decoded.width, 2048)
        XCTAssertLessThanOrEqual(result.count, 2 * 1_024 * 1_024)
    }

    func testScannedPDFIsNotReportedAsReadableText() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)).pdfData { context in
            context.beginPage()
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }
        XCTAssertThrowsError(try MessageAttachments.pdfText(data)) { error in
            guard case AttachmentImportError.emptyPDF = error else { return XCTFail("Expected a missing-text error") }
        }
    }

    func testOversizedTextAndUnsupportedFormatsAreRejectedWithoutCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MessageAttachments(directory: directory)
        do { _ = try await store.importData(Data(repeating: 65, count: 60_001), name: "huge.txt", type: .plainText); XCTFail("Expected a size rejection") }
        catch { XCTAssertTrue(error is AttachmentImportError) }
        do { _ = try await store.importData(Data([1, 2, 3]), name: "app.exe", type: .executable); XCTFail("Expected an unsupported-format rejection") }
        catch { XCTAssertTrue(error is AttachmentImportError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
