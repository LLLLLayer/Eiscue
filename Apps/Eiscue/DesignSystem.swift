import SwiftUI

enum EiscueStyle {
    static let accent = Color("AccentColor")
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
    static let background = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    // Switch thumbs stay white even when the app's monochrome accent turns white.
    static let switchTint = Color(uiColor: .systemGray)
    static let ink = Color.primary
    static let muted = Color.secondary
}

struct IceMark: View {
    var size: CGFloat = 52

    var body: some View {
        Image("MascotCutout")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusLabel: View {
    let title: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: Capsule())
    }
}

struct SectionCaption: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EiscueStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.025))
            }
    }
}
