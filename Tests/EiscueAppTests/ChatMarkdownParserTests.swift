import XCTest
@testable import Eiscue

final class ChatMarkdownParserTests: XCTestCase {
    func testCommonMarkAndGFMBecomeDistinctBlocks() throws {
        let blocks = ChatMarkdownParser.parse("""
        # Title

        Paragraph with **bold**, *italic*, `code` and [link](https://example.com).

        - First
        - Second
          - Nested

        > Quoted paragraph

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | :--- | ---: |
        | One | 1 |
        """)
        XCTAssertEqual(blocks.count, 6)
        guard case .heading(1, let title) = blocks[0].content else { return XCTFail("Missing block heading") }
        XCTAssertEqual(title.map(\.text).joined(), "Title")
        guard case .paragraph(let inline) = blocks[1].content else { return XCTFail("Missing paragraph") }
        XCTAssertTrue(inline.contains { $0.bold && $0.text == "bold" })
        XCTAssertTrue(inline.contains { $0.italic && $0.text == "italic" })
        XCTAssertTrue(inline.contains { $0.code && $0.text == "code" })
        XCTAssertTrue(inline.contains { $0.link?.absoluteString == "https://example.com" })
        guard case .list(let items) = blocks[2].content else { return XCTFail("Missing list") }
        XCTAssertEqual(items.count, 2)
        guard case .list(let nested) = items[1].blocks.last?.content else { return XCTFail("Missing nested list") }
        XCTAssertEqual(nested.count, 1)
        guard case .quote(let quote) = blocks[3].content else { return XCTFail("Missing quote") }
        XCTAssertEqual(quote.count, 1)
        guard case .code("swift", let code) = blocks[4].content else { return XCTFail("Missing code fence") }
        XCTAssertEqual(code, "let answer = 42\n")
        guard case .table(let header, let rows, let alignments) = blocks[5].content else { return XCTFail("Missing GFM table") }
        XCTAssertEqual(header.map { $0.map(\.text).joined() }, ["Name", "Value"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(alignments, [.leading, .trailing])
    }

    func testAppendOnlyStreamingPreservesCompletedBlockIdentityAndCodeWhitespace() throws {
        let prefix = "# Title\n\nCompleted paragraph.\n\n```swift\n  let value"
        let first = ChatMarkdownParser.parse(prefix)
        let appended = ChatMarkdownParser.parse(prefix + " = 1\n```\n\nMore")
        XCTAssertEqual(Array(first.prefix(2)), Array(appended.prefix(2)))
        XCTAssertEqual(first[2].id, appended[2].id)
        guard case .code(_, let incompleteCode) = first[2].content else { return XCTFail("Incomplete fence should still be a code block") }
        XCTAssertEqual(incompleteCode, "  let value\n")
        guard case .code(_, let completeCode) = appended[2].content else { return XCTFail("Missing completed code") }
        XCTAssertEqual(completeCode, "  let value = 1\n")
    }

    func testSelectionTextContainsReadableBlocksAndLinksCannotUseExecutableSchemes() {
        let source = "# Heading\n\n[Safe](https://example.com) and [unsafe](javascript:alert%281%29)\n\n```\ncode\n```"
        let text = ChatMarkdownParser.plainText(source)
        XCTAssertTrue(text.contains("Heading"))
        XCTAssertTrue(text.contains("Safe and unsafe"))
        XCTAssertTrue(text.contains("code"))
        XCTAssertFalse(text.contains("```"))
        let blocks = ChatMarkdownParser.parse(source)
        guard case .paragraph(let inline) = blocks[1].content else { return XCTFail("Missing paragraph") }
        XCTAssertEqual(inline.first { $0.text == "Safe" }?.link?.scheme, "https")
        XCTAssertNil(inline.first { $0.text == "unsafe" }?.link)
    }

    func testTaskListsAndOrderedStartArePreserved() {
        let blocks = ChatMarkdownParser.parse("- [x] Done\n- [ ] Next\n\n3. Third\n4. Fourth")
        guard case .list(let tasks) = blocks[0].content,
              case .list(let numbered) = blocks[1].content else { return XCTFail("Missing lists") }
        XCTAssertEqual(tasks.map(\.marker), ["☑", "☐"])
        XCTAssertEqual(numbered.map(\.marker), ["3.", "4."])
    }
}
