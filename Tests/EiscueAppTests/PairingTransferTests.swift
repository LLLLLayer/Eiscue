import Foundation
import XCTest
@testable import Eiscue

final class PairingTransferTests: XCTestCase {
    func testConsumesTransferWithoutKeepingTemporaryCredentialFile() throws {
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data("test fixture".utf8)
        try data.write(to: file)
        XCTAssertEqual(try PairingTransfer.readAndRemove(at: file), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRejectsOversizeAndSymbolicLinksWithoutReadingTheirTargets() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("link")
        try Data(repeating: 1, count: 32 * 1024 + 1).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try PairingTransfer.readAndRemove(at: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertThrowsError(try PairingTransfer.readAndRemove(at: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
