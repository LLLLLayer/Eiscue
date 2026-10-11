import Foundation

/// Add an asset and a manifest entry to extend the pack without changing the renderer.
struct EiscueSticker: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let assetName: String
    let labelKey: String
    let meaning: String
    var label: String { String(localized: String.LocalizationValue(labelKey), table: "Composer") }
    var token: String { "[[eiscue:\(id)]]" }
}

enum StickerSegment: Equatable {
    case text(String)
    case sticker(EiscueSticker)
}

enum StickerCatalog {
    static let stickers: [EiscueSticker] = {
        guard let url = Bundle.main.url(forResource: "Stickers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([EiscueSticker].self, from: data) else { return [] }
        var seen = Set<String>()
        return entries.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }()

    static var instructions: String {
        guard !stickers.isEmpty else { return "" }
        let rules = Bundle.main.url(forResource: "eiscue-stickers", withExtension: "md", subdirectory: "Skills")
            ?? Bundle.main.url(forResource: "eiscue-stickers", withExtension: "md")
        let text = rules.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return text + "\nAvailable stickers:\n" + stickers.map { "\($0.token): \($0.meaning)" }.joined(separator: "\n")
    }

    /// Only exact, known tokens in assistant messages become local images. No remote URLs execute.
    static func segments(in text: String, catalog: [EiscueSticker] = stickers) -> [StickerSegment] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[eiscue:([a-z0-9-]+)\]\]"#) else { return [.text(text)] }
        let source = text as NSString
        var segments: [StickerSegment] = []
        var cursor = 0
        var rendered = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard rendered < 2,
                  let sticker = catalog.first(where: { $0.id == source.substring(with: match.range(at: 1)) }) else { continue }
            if match.range.location > cursor { segments.append(.text(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))) }
            segments.append(.sticker(sticker))
            rendered += 1
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length { segments.append(.text(source.substring(from: cursor))) }
        return segments.isEmpty ? [.text(text)] : segments
    }
}
