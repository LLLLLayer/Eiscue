import Foundation
import XCTest

final class AppLocalizationTests: XCTestCase {
    func testEnglishAndSimplifiedChineseResolveFromPackagedCatalog() throws {
        for (language, expected) in [("en", "Assistant"), ("zh-Hans", "助手")] {
            let bundle = try languageBundle(language)
            XCTAssertEqual(String(localized: "common.assistant", bundle: bundle), expected)
            XCTAssertFalse(String(localized: "model.serviceRequirements", bundle: bundle).hasPrefix("model."))
        }
    }

    func testEnglishEventCountUsesPluralRules() throws {
        let bundle = try languageBundle("en")
        for (count, expected) in [(0, "0 events"), (1, "1 event"), (2, "2 events")] {
            XCTAssertEqual(
                String(localized: "runs.eventCount \(count)", bundle: bundle, locale: Locale(identifier: "en")),
                expected
            )
        }
    }

    func testLocalizedInterpolationPreservesValues() throws {
        let bundle = try languageBundle("zh-Hans")
        let locale = Locale(identifier: "zh-Hans")
        let count = 2
        XCTAssertEqual(String(localized: "probe.count \(count)", bundle: bundle, locale: locale), "计数：2")
        let status: Int32 = -50
        let error = String(localized: "credentials.operationFailed \(status)", bundle: bundle, locale: locale)
        XCTAssertTrue(error.contains("-50"))
        XCTAssertFalse(error.contains("credentials."))
        let width = 390, height = 844, frameID = "00000000-0000-0000-0000-000000000001"
        XCTAssertEqual(
            String(localized: "event.capturedMetadata \(width) \(height) \(frameID)", bundle: bundle, locale: locale),
            "390 × 844，截图编号 00000000-0000-0000-0000-000000000001"
        )
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }
}
