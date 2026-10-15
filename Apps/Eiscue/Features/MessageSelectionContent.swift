import UIKit

@MainActor enum MessageSelectionContent {
    static func make(text: String, markdown: Bool, foregroundColor: UIColor, traits: UITraitCollection) -> NSAttributedString {
        func font(_ style: UIFont.TextStyle, bold: Bool = false, italic: Bool = false, code: Bool = false) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
            var descriptor = base.fontDescriptor
            if code { descriptor = descriptor.withDesign(.monospaced) ?? descriptor }
            var symbolic = descriptor.symbolicTraits
            if bold { symbolic.insert(.traitBold) }
            if italic { symbolic.insert(.traitItalic) }
            descriptor = descriptor.withSymbolicTraits(symbolic) ?? descriptor
            return UIFont(descriptor: descriptor, size: base.pointSize)
        }
        let body: [NSAttributedString.Key: Any] = [.font: font(.body), .foregroundColor: foregroundColor]
        guard markdown else { return NSAttributedString(string: text, attributes: body) }

        func inline(_ runs: [ChatMarkdownInline], style: UIFont.TextStyle = .body, bold: Bool = false) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(string: "")
            for run in runs {
                var attributes = body
                attributes[.font] = font(run.code ? .body : style, bold: bold || run.bold, italic: run.italic, code: run.code)
                if run.code { attributes[.backgroundColor] = foregroundColor.withAlphaComponent(0.07) }
                if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link {
                    attributes[.link] = link
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            return result
        }
        func paragraph(_ text: NSMutableAttributedString, indent: CGFloat, spacing: CGFloat = 8) -> NSMutableAttributedString {
            text.append(NSAttributedString(string: "\n", attributes: body))
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent; style.headIndent = indent; style.paragraphSpacing = spacing
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            return text
        }
        func blocks(_ values: [ChatMarkdownBlock], indent: CGFloat = 0) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(string: "")
            for block in values {
                switch block.content {
                case .paragraph(let runs): result.append(paragraph(inline(runs), indent: indent))
                case .heading(let level, let runs):
                    let style: UIFont.TextStyle = level == 1 ? .title2 : level == 2 ? .title3 : .headline
                    result.append(paragraph(inline(runs, style: style, bold: true), indent: indent, spacing: 10))
                case .code(_, let source):
                    var attributes = body
                    attributes[.font] = font(.callout, code: true)
                    attributes[.backgroundColor] = foregroundColor.withAlphaComponent(0.07)
                    result.append(paragraph(NSMutableAttributedString(string: source.trimmingCharacters(in: .newlines), attributes: attributes),
                                            indent: indent + 12, spacing: 12))
                case .quote(let children):
                    let quote = blocks(children, indent: indent + 13)
                    quote.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(location: 0, length: quote.length))
                    result.append(quote)
                case .list(let items):
                    for item in items {
                        let content = blocks(item.blocks, indent: indent + 28)
                        content.insert(NSAttributedString(string: item.marker + " ", attributes: body), at: 0)
                        if !content.string.hasSuffix("\n") { content.append(NSAttributedString(string: "\n", attributes: body)) }
                        let firstLine = (content.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                        let style = NSMutableParagraphStyle()
                        style.firstLineHeadIndent = indent; style.headIndent = indent + 28; style.paragraphSpacing = 4
                        content.addAttribute(.paragraphStyle, value: style, range: firstLine)
                        result.append(content)
                    }
                case .table(let header, let rows, _):
                    for (rowIndex, cells) in ([header] + rows).enumerated() {
                        let row = NSMutableAttributedString(string: "")
                        for (cellIndex, runs) in cells.enumerated() {
                            if cellIndex > 0 { row.append(NSAttributedString(string: "\t", attributes: body)) }
                            row.append(inline(runs, style: .subheadline, bold: rowIndex == 0))
                        }
                        let line = paragraph(row, indent: indent, spacing: 4)
                        let style = NSMutableParagraphStyle()
                        style.firstLineHeadIndent = indent; style.headIndent = indent
                        style.defaultTabInterval = 120; style.tabStops = []; style.paragraphSpacing = 4
                        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                        result.append(line)
                    }
                case .divider: result.append(paragraph(NSMutableAttributedString(string: ""), indent: indent))
                }
            }
            return result
        }

        let result = NSMutableAttributedString(string: "")
        for segment in StickerCatalog.segments(in: text) {
            switch segment {
            case .text(let value): result.append(blocks(ChatMarkdownParser.parse(value)))
            case .sticker(let sticker):
                result.append(paragraph(NSMutableAttributedString(string: sticker.label, attributes: body), indent: 0, spacing: 10))
            }
        }
        if result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }
}
