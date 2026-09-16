import SwiftUI

/// 1–5 star control. `rating` of 0 means unrated. Tap a star to set; tap the
/// current star again to clear. Set `editable = false` for a display-only row.
struct StarRating: View {
    @Binding var rating: Int
    var editable = true
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i <= rating ? .yellow : Color.secondary.opacity(0.4))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard editable else { return }
                        rating = (rating == i) ? 0 : i
                    }
                    .accessibilityLabel("\(i) star\(i == 1 ? "" : "s")")
            }
        }
    }
}

/// Compact read-only star row for list cells.
struct StarsInline: View {
    let rating: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(i <= rating ? .yellow : Color.secondary.opacity(0.35))
            }
        }
    }
}

/// A critic or community score on the 100-point scale, as a filled pill.
/// Banded like the trade reads them: 95+ is exceptional, 90+ outstanding,
/// 85+ very good, below that ordinary — so the number carries at a glance.
struct ScoreBadge: View {
    let score: Int
    var compact = false
    /// Hero treatment, for the top of a wine's own screen.
    var large = false

    private var tint: Color {
        switch score {
        case 95...: return Color(red: 0.70, green: 0.51, blue: 0.11)   // gold
        case 90..<95: return Color(red: 0.16, green: 0.48, blue: 0.24) // green
        case 85..<90: return Color(red: 0.16, green: 0.40, blue: 0.56) // blue
        default: return Color.secondary
        }
    }

    private var font: Font {
        if large { return .title2.weight(.bold) }
        return compact ? .caption2.weight(.bold) : .subheadline.weight(.bold)
    }

    var body: some View {
        Text("\(score)")
            .font(font)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 14 : (compact ? 6 : 9))
            .padding(.vertical, large ? 7 : (compact ? 2 : 4))
            .background(tint, in: Capsule())
            .accessibilityLabel("Score \(score) out of 100")
    }
}

/// Wine label image with a graceful fallback chain:
/// scanned/added photo → database image URL → type-tinted placeholder.
struct WineThumbnail: View {
    let imageData: Data?
    let imageURL: String?
    let type: WineType
    var width: CGFloat = 48
    var height: CGFloat = 64
    var corner: CGFloat = 8

    var body: some View {
        Group {
            if let imageData, let ui = UIImage(data: imageData) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if let s = imageURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.black.opacity(0.08)))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [type.tint.opacity(0.85), type.tint.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "wineglass.fill")
                .font(.system(size: width * 0.4))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
