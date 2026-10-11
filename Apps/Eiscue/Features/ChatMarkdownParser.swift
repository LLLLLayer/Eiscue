import Foundation
import Markdown

/// CommonMark + GFM are parsed by swift-markdown. Positions, rather than content,
/// identify blocks so an appended streaming token does not recreate earlier views.
struct ChatMarkdownBlock: Identifiable, Equatable, Sendable {
    let id: String
    let content: Content

    indirect enum Content: Equatable, Sendable {
        case paragraph([ChatMarkdownInline])
        case heading(Int, [ChatMarkdownInline])
        case code(language: String?, source: String)
        case quote([ChatMarkdownBlock])
        case list([ChatMarkdownListItem])
        case table(header: [[ChatMarkdownInline]], rows: [[[ChatMarkdownInline]]], alignments: [Alignment])
        case divider
    }
    enum Alignment: Equatable, Sendable { case leading, center, trailing }
}

struct ChatMarkdownInline: Equatable, Sendable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var strikethrough = false
    var link: URL?
}

struct ChatMarkdownListItem: Identifiable, Equatable, Sendable {
    let id: String
    let marker: String
    let blocks: [ChatMarkdownBlock]
}

enum ChatMarkdownParser {
    static func parse(_ source: String) -> [ChatMarkdownBlock] {
        blocks(in: Document(parsing: source, options: [.disableSmartOpts]), path: "root")
    }

    private static func blocks(in parent: any Markup, path: String) -> [ChatMarkdownBlock] {
        parent.children.enumerated().compactMap { offset, node in
            let position = node.range?.lowerBound
            let id = position.map { "\(path)/\($0.line):\($0.column)" } ?? "\(path)/\(offset)"
            let content: ChatMarkdownBlock.Content
            switch node {
            case let heading as Heading: content = .heading(heading.level, inline(heading))
            case let paragraph as Paragraph: content = .paragraph(inline(paragraph))
            case let code as CodeBlock: content = .code(language: code.language, source: code.code)
            case let quote as BlockQuote: content = .quote(blocks(in: quote, path: id))
            case let list as OrderedList:
                content = .list(list.listItems.enumerated().map { offset, item in
                    listItem(item, marker: "\(list.startIndex + UInt(offset)).", id: "\(id)/\(offset)")
                })
            case let list as UnorderedList:
                content = .list(list.listItems.enumerated().map { offset, item in
                    listItem(item, marker: "•", id: "\(id)/\(offset)")
                })
            case let table as Table:
                content = .table(header: table.head.children.map { inline($0) },
                                 rows: table.body.rows.map { $0.children.map { inline($0) } },
                                 alignments: table.columnAlignments.map {
                                     switch $0 { case .center: .center; case .right: .trailing; default: .leading }
                                 })
            case is ThematicBreak: content = .divider
            case let html as HTMLBlock: content = .paragraph([.init(text: html.rawHTML)])
            default:
                let children = blocks(in: node, path: id)
                guard !children.isEmpty else { return nil }
                content = .quote(children)
            }
            return ChatMarkdownBlock(id: id, content: content)
        }
    }

    private static func listItem(_ item: ListItem, marker: String, id: String) -> ChatMarkdownListItem {
        let marker: String = switch item.checkbox { case .checked: "☑"; case .unchecked: "☐"; default: marker }
        return ChatMarkdownListItem(id: id, marker: marker, blocks: blocks(in: item, path: id))
    }

    private static func inline(_ parent: any Markup, style: ChatMarkdownInline = .init(text: "")) -> [ChatMarkdownInline] {
        var style = style
        switch parent {
        case let text as Markdown.Text: style.text = text.string; return [style]
        case let code as InlineCode: style.text = code.code; style.code = true; return [style]
        case is SoftBreak: style.text = "\n"; return [style]
        case is LineBreak: style.text = "\n"; return [style]
        case is Strong: style.bold = true
        case is Emphasis: style.italic = true
        case is Strikethrough: style.strikethrough = true
        case let link as Markdown.Link: style.link = safeURL(link.destination)
        case let image as Markdown.Image:
            // Remote Markdown images are links rather than automatic network requests.
            // Actual user/Agent image attachments use MessageAttachmentView.
            style.link = safeURL(image.source)
            let label = image.plainText
            style.text = label.isEmpty ? (image.source ?? "") : label
            return [style]
        case let html as InlineHTML: style.text = html.rawHTML; return [style]
        default: break
        }
        return parent.children.flatMap { inline($0, style: style) }
    }

    private static func safeURL(_ source: String?) -> URL? {
        guard let source, let url = URL(string: source),
              let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return nil }
        return url
    }

    static func plainText(_ source: String) -> String { plainText(parse(source)) }
    private static func plainText(_ blocks: [ChatMarkdownBlock]) -> String {
        blocks.map { block in
            switch block.content {
            case .paragraph(let runs), .heading(_, let runs): runs.map(\.text).joined()
            case .code(_, let source): source
            case .quote(let blocks): plainText(blocks)
            case .list(let items): items.map { "\($0.marker) \(plainText($0.blocks))" }.joined(separator: "\n")
            case .table(let header, let rows, _): ([header] + rows).map { $0.map { $0.map(\.text).joined() }.joined(separator: "\t") }.joined(separator: "\n")
            case .divider: ""
            }
        }.joined(separator: "\n\n")
    }
}
