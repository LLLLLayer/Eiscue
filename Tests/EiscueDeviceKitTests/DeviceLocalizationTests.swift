import Foundation
import Testing
@testable import EiscueDeviceKit

@Suite struct DeviceLocalizationTests {
    @Test func englishAndSimplifiedChineseResourcesHaveMatchingKeysAndArguments() throws {
        let english = try resources(language: "en")
        let chinese = try resources(language: "zh-Hans")
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(chinese.keys))
        for (key, value) in english {
            let translated = try #require(chinese[key])
            #expect(!value.isEmpty && !translated.isEmpty)
            #expect(value != key && translated != key)
            #expect(value.components(separatedBy: "%@").count == translated.components(separatedBy: "%@").count)
        }
        #expect(english["device.error.not-connected"] != chinese["device.error.not-connected"])
    }

    @Test func publicErrorsKeepTypedIdentityAndFormatParameters() {
        let expected = NSLocalizedString("device.error.stale-frame", bundle: .module, value: "MISSING RESOURCE", comment: "")
        #expect(DeviceControlError.staleFrame.errorDescription == expected)
        #expect(DeviceControlError.staleFrame == .staleFrame)
        let keychain = DeviceControlError.keychain(-34018).localizedDescription
        #expect(keychain.contains("-34018"))
        #expect(!keychain.contains("%@"))
        let unknown = DeviceControlError.deliveryUnknown("receipt-unconfirmed")
        #expect(unknown.isDeliveryUnknown)
        #expect(unknown.localizedDescription.contains("receipt-unconfirmed"))
        #expect(!unknown.localizedDescription.contains("%@"))
    }

    @Test(arguments: ["en", "zh-Hans"])
    func bothLanguagesCanBeReadAndFormattedByFoundation(language: String) throws {
        let resource = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        let bundle = try #require(Bundle(url: resource.deletingLastPathComponent()))
        let message = String(localized: "device.backend.protocol-failed",
                             defaultValue: "MISSING RESOURCE \(String(12)) \(String(34))", bundle: bundle)
        #expect(message.contains("12") && message.contains("34"))
        #expect(!message.contains("MISSING RESOURCE"))
        #expect(!message.contains("%@"))
    }

    private func resources(language: String) throws -> [String: String] {
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String])
    }
}
