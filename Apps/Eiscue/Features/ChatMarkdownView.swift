import SwiftUI

struct ChatMarkdownView: View, Equatable {
    let source: String
    var body: some View {
        ChatMarkdownBlocks(blocks: ChatMarkdownParser.parse(source))
            .tint(.primary)
            .transaction { $0.animation = nil }
    }
}

private struct ChatMarkdownBlocks: View {
    let blocks: [ChatMarkdownBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in ChatMarkdownBlockView(block: block).equatable() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatMarkdownBlockView: View, Equatable {
    let block: ChatMarkdownBlock
    var body: some View {
        switch block.content {
        case .paragraph(let runs):
            inlineText(runs).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("markdownParagraph")
        case .heading(let level, let runs):
            inlineText(runs, base: headingFont(level)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("markdownHeading")
        case .code(let language, let source):
            codeBlock(language: language, source: source)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                AnyView(ChatMarkdownBlocks(blocks: blocks)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("markdownQuote")
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.marker).monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                        AnyView(ChatMarkdownBlocks(blocks: item.blocks))
                    }.accessibilityIdentifier("markdownListItem")
                }
            }
        case .table(let header, let rows, let alignments):
            table(header: header, rows: rows, alignments: alignments)
        case .divider: Divider().padding(.vertical, 2)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level { case 1: .title2.bold(); case 2: .title3.bold(); default: .headline }
    }

    private func inlineText(_ runs: [ChatMarkdownInline], base: Font = .body) -> Text {
        var result = AttributedString()
        for run in runs {
            var text = AttributedString(run.text)
            var font = run.code ? Font.body.monospaced() : base
            if run.bold { font = font.bold() }
            if run.italic { font = font.italic() }
            text.font = font
            if run.strikethrough { text.strikethroughStyle = .single }
            if let link = run.link { text.link = link; text.underlineStyle = .single }
            if run.code { text.backgroundColor = Color.primary.opacity(0.07) }
            result.append(text)
        }
        return Text(result)
    }

    private func codeBlock(language: String?, source: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? chatText("chat.code"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button { UIPasteboard.general.string = source } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(chatText("chat.copyCode"))
            }
            ScrollView(.horizontal) {
                Text(verbatim: source.trimmingCharacters(in: .newlines))
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }.padding(12).background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("markdownCodeBlock")
    }

    private func table(header: [[ChatMarkdownInline]], rows: [[[ChatMarkdownInline]]],
                       alignments: [ChatMarkdownBlock.Alignment]) -> some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(header, alignments: alignments, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    tableRow(cells, alignments: alignments, isHeader: false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }.scrollBounceBehavior(.basedOnSize, axes: .horizontal).accessibilityIdentifier("markdownTable")
    }

    private func tableRow(_ cells: [[ChatMarkdownInline]], alignments: [ChatMarkdownBlock.Alignment], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { offset, runs in
                let alignment: Alignment = switch alignments.indices.contains(offset) ? alignments[offset] : .leading {
                case .leading: .leading; case .center: .center; case .trailing: .trailing
                }
                inlineText(runs, base: isHeader ? .subheadline.bold() : .subheadline)
                    .textSelection(.enabled).frame(minWidth: 100, maxWidth: 230, alignment: alignment)
                    .fixedSize(horizontal: false, vertical: true).padding(8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background { if isHeader { Rectangle().fill(Color.primary.opacity(0.07)) } }
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
        }
    }
}

func chatText(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Chat") }
