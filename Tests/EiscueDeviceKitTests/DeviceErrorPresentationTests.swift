import Foundation
import Testing
@testable import EiscueDeviceKit
import PhoneAgentNCM

@Suite struct DeviceErrorPresentationTests {
    @Test func unavailableScreenExplainsCompletedPairingAndChatInBothLanguages() throws {
        let error = NativeBackendError.touchPreparationFailure(stage: 10, cause: 4)
        #expect(try message(error, language: "zh-Hans") == "配对已完成，但当前连接暂时无法读取屏幕。仍可继续聊天。")
        #expect(try message(error, language: "en") == "Pairing succeeded, but screen access is unavailable on this connection. Device control is unavailable; chat still works.")
    }

    @Test func unavailableInputIsNotReportedAsUnavailableScreen() throws {
        let text = try message(.touchPreparationFailure(stage: 11, cause: 4), language: "en")
        #expect(text.contains("touch input"))
        #expect(!text.contains("screen access"))
        #expect(text.contains("Pairing succeeded"))
    }

    @Test func slowServiceCanBeRetriedWithoutClaimingItIsMissing() throws {
        for stage: UInt32 in [10, 11, 14, 17] {
            let text = try message(.touchPreparationFailure(stage: stage, cause: 2), language: "en")
            #expect(text.contains("timed out"))
            #expect(text.contains("reconnect"))
            #expect(!text.contains("unavailable"))
        }
    }

    @Test func earlierFailuresDoNotClaimPairingSucceeded() throws {
        for stage: UInt32 in [1, 2, 3, 4, 5, 6, 7, 8] {
            for cause: UInt32 in [1, 2, 4, 5] {
                let text = try message(.protocolFailure(stage: stage, cause: cause), language: "en")
                #expect(!text.contains("Pairing succeeded"))
                #expect(try !message(.protocolFailure(stage: stage, cause: cause), language: "zh-Hans").contains("配对已完成"))
                if cause == 2 { #expect(text.contains("did not respond in time")) }
            }
        }
        #expect(try message(.protocolFailure(stage: 7, cause: 5), language: "en").contains("Developer Mode"))
        #expect(try message(.protocolFailure(stage: 8, cause: 5), language: "en").contains("Xcode"))
    }

    @Test func automationErrorsGiveInstructionsWithoutReinterpretingBridgeCodes() throws {
        #expect(try message(.touchPreparationFailure(stage: 38, cause: 8), language: "en").contains("system permission"))
        #expect(try message(.touchPreparationFailure(stage: 38, cause: 9), language: "zh-Hans").contains("方向不变"))
        #expect(try message(.touchPreparationFailure(stage: 38, cause: 14), language: "en").contains("timed out"))
        #expect(try !message(.touchPreparationFailure(stage: 38, cause: 2), language: "en").contains("timed out"))
        #expect(try message(.automationDeliveryUnknown(cause: 11), language: "en").contains("will not be repeated"))
        for language in ["en", "zh-Hans"] {
            let text = try message(.automationAuthorizationTimedOut, language: language)
            #expect(!text.contains("screen access"))
            #expect(!text.contains("未获得"))
            #expect(text.contains(language == "en" ? "system’s Enable UI Automation screen" : "系统页面"))
        }
    }

    @Test func nativeCodesAreNotExposedInMainErrorText() throws {
        let errors: [NativeBackendError] = [
            .protocolFailure(stage: 3, cause: 1),
            .touchPreparationFailure(stage: 10, cause: 4),
            .touchPreparationFailure(stage: 999, cause: 999),
            .screenshotFailure(stage: 19, cause: 2),
            .applicationQueryFailure(stage: 21, cause: 1),
            .transport(code: -999),
            .touchPreparationFailure(stage: 38, cause: 8),
            .touchPreparationFailure(stage: 38, cause: 14),
            .automationDeliveryUnknown(cause: 11),
            .automationAuthorizationTimedOut,
        ]
        for language in ["en", "zh-Hans"] {
            for error in errors {
                let text = try message(error, language: language)
                #expect(!text.isEmpty)
                let containsCode = text.contains(where: \.isNumber)
                #expect(!containsCode)
                #expect(!text.contains("stage"))
                #expect(!text.contains("cause"))
                #expect(!text.contains("阶段"))
                #expect(!text.contains("原因"))
                #expect(!text.contains("%@"))
            }
        }
    }

    private func message(_ error: NativeBackendError, language: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        let bundle = try #require(Bundle(url: url.deletingLastPathComponent()))
        return NativeDeviceErrorPresentation.message(error, bundle: bundle)
    }
}
