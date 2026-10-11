import XCTest
@testable import Eiscue

final class StickerCatalogTests: XCTestCase {
    private let wave = EiscueSticker(id: "wave", assetName: "StickerWave", labelKey: "sticker.wave", meaning: "Hello")

    func testKnownTokenPreservesSurroundingUnicode() {
        XCTAssertEqual(StickerCatalog.segments(in: "你好 👋\n[[eiscue:wave]]\n再见", catalog: [wave]),
                       [.text("你好 👋\n"), .sticker(wave), .text("\n再见")])
    }

    func testUnknownAndIncompleteTokensStayText() {
        let input = "[[eiscue:unknown]] [[eiscue:wave"
        XCTAssertEqual(StickerCatalog.segments(in: input, catalog: [wave]), [.text(input)])
    }

    func testStickerFloodIsBoundedAndManifestAssetsExist() {
        let input = String(repeating: wave.token, count: 5)
        let segments = StickerCatalog.segments(in: input, catalog: [wave])
        XCTAssertEqual(segments.filter { if case .sticker = $0 { true } else { false } }.count, 2)
        XCTAssertFalse(StickerCatalog.stickers.isEmpty)
        for sticker in StickerCatalog.stickers { XCTAssertNotNil(UIImage(named: sticker.assetName)) }
    }
}
