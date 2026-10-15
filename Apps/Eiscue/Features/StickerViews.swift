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
    @State private var previewState: EiscueHeadState = .awake

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "mascot.gallery.title", table: "Mascot"))
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Picker(String(localized: "mascot.gallery.preview", table: "Mascot"), selection: $previewState) {
                        ForEach(EiscueHeadState.allCases) { state in Text(state.title).tag(state) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mascotPreviewState")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 16) {
                        ForEach(EiscueHeadStyle.allCases) { style in
                            VStack(spacing: 8) {
                                EiscueHeadView(style: style, state: previewState)
                                    .frame(height: 116)
                                    .accessibilityIdentifier("mascotPreview_\(style.rawValue)")
                                Text(style.title).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(12)
                            .background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 20))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(localized: "mascot.gallery.stickers", table: "Mascot"))
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 24) {
                        ForEach(StickerCatalog.stickers) { sticker in
                            VStack(spacing: 8) {
                                Image(sticker.assetName).resizable().scaledToFit().frame(height: 120)
                                    .accessibilityHidden(true)
                                Text(sticker.label).font(.subheadline)
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
            }.frame(maxWidth: 700).padding(24).frame(maxWidth: .infinity)
            Text(String(localized: "composer.stickersHint", table: "Composer"))
                .font(.subheadline).foregroundStyle(.secondary).padding()
        }
        .background(EiscueStyle.background)
        .navigationTitle(String(localized: "composer.stickers", table: "Composer"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
