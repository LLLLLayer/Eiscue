import Foundation
import Testing
@testable import EiscueAgentKit

@Suite struct AgentLocalizationTests {
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
        #expect(english["agent.conversation.new-title"] != chinese["agent.conversation.new-title"])
    }

    @Test func defaultConversationTitleUsesItsKitBundleWithoutReplacingExplicitTitles() {
        let expected = NSLocalizedString("agent.conversation.new-title", bundle: .module,
                                         value: "MISSING RESOURCE", comment: "")
        #expect(expected != "MISSING RESOURCE")
        #expect(Conversation().title == expected)
        #expect(Conversation(title: "").title.isEmpty)
        #expect(Conversation(title: "User supplied title").title == "User supplied title")
    }

    @Test func publicErrorsKeepTypedIdentityAndFormatParameters() {
        let expected = NSLocalizedString("agent.error.busy", bundle: .module, value: "MISSING RESOURCE", comment: "")
        #expect(AgentError.busy.errorDescription == expected)
        #expect(AgentError.busy == .busy)
        let versionError = ConversationStoreError.unsupportedVersion(97).localizedDescription
        #expect(versionError.contains("97"))
        #expect(!versionError.contains("%@"))
        #expect(!versionError.contains("agent.storage."))
    }

    @Test(arguments: ["en", "zh-Hans"])
    func bothLanguagesCanBeReadAndFormattedByFoundation(language: String) throws {
        let resource = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        let bundle = try #require(Bundle(url: resource.deletingLastPathComponent()))
        let message = String(localized: "agent.storage.unsupported-version",
                             defaultValue: "MISSING RESOURCE \(String(97))", bundle: bundle)
        #expect(message.contains("97"))
        #expect(!message.contains("MISSING RESOURCE"))
        #expect(!message.contains("%@"))
    }

    private func resources(language: String) throws -> [String: String] {
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String])
    }
}
