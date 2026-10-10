import CryptoKit
import Foundation

struct AgentSkill: Identifiable, Equatable {
    let id: String
    let name: String
    let text: String
    let source: String
    let digest: String
    let isBuiltIn: Bool

    init(id: String, text: String, source: String, isBuiltIn: Bool) {
        self.id = id; self.text = text; self.source = source; self.isBuiltIn = isBuiltIn
        let contentName = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)) } ?? id
        if isBuiltIn {
            name = switch id {
            case "ios-navigation": String(localized: "skills.navigationName")
            case "search-smoke-test": String(localized: "skills.searchName")
            case "failure-recovery": String(localized: "skills.recoveryName")
            default: contentName
            }
        } else {
            name = contentName
        }
        digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SkillLibrary {
    let directory: URL

    func load() throws -> [AgentSkill] {
        let bundled = ["ios-navigation", "search-smoke-test", "failure-recovery"].compactMap { id -> AgentSkill? in
            guard let url = Bundle.main.url(forResource: id, withExtension: "md", subdirectory: "Skills") ?? Bundle.main.url(forResource: id, withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return AgentSkill(id: id, text: text, source: String(localized: "skills.builtInSource"), isBuiltIn: true)
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return bundled }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let imported = try urls.filter { $0.pathExtension == "md" }.map { url in
            AgentSkill(id: url.deletingPathExtension().lastPathComponent,
                       text: try String(contentsOf: url, encoding: .utf8), source: String(localized: "skills.importedSource"), isBuiltIn: false)
        }
        return bundled + imported.sorted { $0.name < $1.name }
    }

    func importFile(_ url: URL) throws -> AgentSkill {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { throw SkillError.invalidFile }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? .max) <= 65_536 else { throw SkillError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillError.invalidFile }
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(id).appendingPathExtension("md"), options: .atomic)
        return AgentSkill(id: id, text: text, source: String(localized: "skills.importedSource"), isBuiltIn: false)
    }

    func delete(_ skill: AgentSkill) throws {
        guard !skill.isBuiltIn, UUID(uuidString: skill.id) != nil else { return }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(skill.id).appendingPathExtension("md"))
    }
}

enum SkillError: LocalizedError {
    case invalidFile, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidFile: String(localized: "skills.invalidFile")
        case .tooLarge: String(localized: "skills.tooLarge")
        }
    }
}
