import SwiftUI

struct AssistantMessageContent: View, Equatable {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(StickerCatalog.segments(in: text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let value):
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ChatMarkdownView(source: value).equatable()
                    }
                case .sticker(let sticker):
                    Image(sticker.assetName).resizable().scaledToFit().frame(width: 144, height: 144)
                        .accessibilityLabel(sticker.label)
                        .accessibilityIdentifier("assistantSticker-\(sticker.id)")
                }
            }
        }
    }
}

struct StickerGalleryView: View {
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 24) {
                ForEach(StickerCatalog.stickers) { sticker in
                    VStack(spacing: 8) {
                        Image(sticker.assetName).resizable().scaledToFit().frame(height: 120)
                            .accessibilityHidden(true)
                        Text(sticker.label).font(.subheadline)
                    }.frame(maxWidth: .infinity)
                }
            }.padding(24)
            Text(String(localized: "composer.stickersHint", table: "Composer"))
                .font(.subheadline).foregroundStyle(.secondary).padding()
        }
        .background(EiscueStyle.background)
        .navigationTitle(String(localized: "composer.stickers", table: "Composer"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
