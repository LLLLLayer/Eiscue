import Foundation
import XCTest
@testable import Eiscue

final class LocalizationResourcesTests: XCTestCase {
    func testEnglishAndChineseTablesAreBundled() throws {
        let app = Bundle(for: AppModel.self)
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for (table, key) in [("Runtime", "settings.title"), ("Localizable", "common.device"),
                                 ("Connections", "notifications.task.completed"),
                                 ("TaskStatus", "task.status.phase.waiting"),
                                 ("InfoPlist", "NSLocalNetworkUsageDescription"),
                                 ("InfoPlist", "NSCameraUsageDescription"),
                                 ("InfoPlist", "NSMicrophoneUsageDescription"),
                                 ("InfoPlist", "NSSpeechRecognitionUsageDescription"),
                                 ("Composer", "composer.controlDevice"),
                                 ("Chat", "chat.operatingDevice"),
                                 ("Speech", "speech.start"),
                                 ("Attachments", "attachment.error.fileSize"),
                                 ("Navigation", "sidebar.settings")] {
                let translated = bundle.localizedString(forKey: key, value: nil, table: table)
                XCTAssertNotEqual(translated, key, "Missing \(language)/\(table)/\(key)")
                XCTAssertFalse(translated.isEmpty)
            }
            XCTAssertEqual(bundle.localizedString(forKey: "settings.title", value: nil, table: "Runtime"),
                           language == "en" ? "Settings" : "设置")
        }
    }

    func testRuntimeErrorInterpolationKeepsTranslatedContext() throws {
        let app = Bundle(for: AppModel.self)
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let format = bundle.localizedString(forKey: "error.save_run", value: nil, table: "Runtime")
            let message = String(format: format, "fixture-detail")
            XCTAssertTrue(message.hasSuffix("fixture-detail"))
            XCTAssertFalse(message.contains("%@"))
            XCTAssertNotEqual(message, "error.save_run")
        }
    }
}
