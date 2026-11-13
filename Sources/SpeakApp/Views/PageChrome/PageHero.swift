import SpeakCore
import SwiftUI

// The gradient header at the top of every main-window page. `PageHeroHeader`
// and `PageHeroStrip` give their whole content white text and a dark colour
// scheme, so a label added later cannot fall back to black on the gradient.
// Fonts and colours come from `SpeakTextStyle`.

/// The gradient and page tint for each main-window page.
enum PageHeroPalette {
    case dashboard
    case history
    case voiceOutput
    case corrections
    case troubleshooting
    case settings

    var colors: [Color] {
        switch self {
        case .dashboard, .history:
            return [Color.brandAccentDeep, Color.brandAccentWarm.opacity(0.9)]
        case .voiceOutput:
            return [Color.green, Color.mint.opacity(0.8)]
        case .corrections:
            return [Color.brandAccentWarm, Color.brandAccent.opacity(0.85)]
        case .troubleshooting:
            return [Color.brandLagoonDeep, Color.blue.opacity(0.75)]
        case .settings:
            return [Color.orange, Color.orange.opacity(0.7)]
        }
    }

    /// The hero's glow and the faint wash behind the page.
    var glow: Color {
        switch self {
        case .dashboard, .history: return .brandAccent
        case .voiceOutput: return .green
        case .corrections: return .brandAccentWarm
        case .troubleshooting: return .brandLagoonDeep
        case .settings: return .orange
        }
    }
}

extension View {
    /// The faint page-wide wash behind a page that carries a page header.
    func pageBackground(_ palette: PageHeroPalette) -> some View {
        background(
            LinearGradient(
                colors: [palette.glow.opacity(0.06), Color(nsColor: .windowBackgroundColor)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    fileprivate func pageHeroSurface(
        _ palette: PageHeroPalette,
        cornerRadius: CGFloat,
        startPoint: UnitPoint,
        endPoint: UnitPoint
    ) -> some View {
        foregroundStyle(SpeakTextStyle.onTint)
            .environment(\.colorScheme, .dark)
            .background(
                LinearGradient(colors: palette.colors, startPoint: startPoint, endPoint: endPoint),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// The full-size page header: title, subtitle, trailing actions and an optional
/// row of filters or `HeroStatChip`s beneath.
struct PageHeroHeader<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let palette: PageHeroPalette
    let accessory: Accessory
    let content: Content

    init(
        _ title: String,
        subtitle: String?,
        palette: PageHeroPalette,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.palette = palette
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(SpeakTextStyle.pageTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(SpeakTextStyle.minimumScaleFactor)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(SpeakTextStyle.pageSubtitle)
                            .foregroundStyle(SpeakTextStyle.onTintSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageHeroSurface(palette, cornerRadius: 32, startPoint: .topLeading, endPoint: .bottomTrailing)
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(SpeakTextStyle.onTintStroke, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: palette.glow.opacity(0.3), radius: 24, x: 0, y: 16)
    }
}

extension PageHeroHeader where Accessory == EmptyView {
    init(
        _ title: String,
        subtitle: String?,
        palette: PageHeroPalette,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, subtitle: subtitle, palette: palette, accessory: { EmptyView() }, content: content)
    }
}

extension PageHeroHeader where Accessory == EmptyView, Content == EmptyView {
    init(_ title: String, subtitle: String?, palette: PageHeroPalette) {
        self.init(title, subtitle: subtitle, palette: palette, accessory: { EmptyView() }, content: { EmptyView() })
    }
}

/// The compact-density page header: one strip with the page label followed by
/// `trailing` (metrics, filters, actions), and an optional row beneath.
struct PageHeroStrip<Trailing: View, Below: View>: View {
    @Environment(\.appVisualDensity) private var density
    let title: String
    let systemImage: String
    let palette: PageHeroPalette
    let trailing: Trailing
    let below: Below

    init(
        _ title: String,
        systemImage: String,
        palette: PageHeroPalette,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder below: () -> Below
    ) {
        self.title = title
        self.systemImage = systemImage
        self.palette = palette
        self.trailing = trailing()
        self.below = below()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: density.inlineSpacing) {
                Label(title, systemImage: systemImage)
                    .font(SpeakTextStyle.stripTitle)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                trailing
            }
            below
        }
        .padding(density.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageHeroSurface(
            palette,
            cornerRadius: density.cardCornerRadius,
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

extension PageHeroStrip where Below == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        palette: PageHeroPalette,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title, systemImage: systemImage, palette: palette, trailing: trailing, below: { EmptyView() })
    }
}

/// A titled figure shown as a `CompactHeroMetric` or a `HeroStatChip`.
struct HeroFigure {
    let title: String
    let value: String
    let systemImage: String
}

/// One figure in a `PageHeroStrip`, read as "title: value".
struct CompactHeroMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        Label(value, systemImage: systemImage)
            .font(SpeakTextStyle.compactMetric)
            .speakSingleLine(fullText: "\(title): \(value)")
            .accessibilityLabel("\(title): \(value)")
    }
}

/// One figure in a `PageHeroHeader`.
struct HeroStatChip: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(SpeakTextStyle.onTintSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(SpeakTextStyle.chipTitle)
                    .foregroundStyle(SpeakTextStyle.onTintTertiary)
                    .lineLimit(1)
                Text(value)
                    .font(SpeakTextStyle.chipValue)
                    .foregroundStyle(SpeakTextStyle.onTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(SpeakTextStyle.minimumScaleFactor)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SpeakTextStyle.onTintFill)
        )
        .accessibilityElement(children: .combine)
        .speakTooltip("\(title): \(value)")
    }
}

/// A short statement on a page header, such as how the page's feature behaves.
/// In a `PageHeroStrip` pass `iconOnly` to show just the symbol.
struct PageHeroBadge: View {
    let title: String
    let systemImage: String
    var iconOnly = false

    var body: some View {
        if iconOnly {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .speakTooltip(title)
        } else {
            Label(title, systemImage: systemImage)
                .font(SpeakTextStyle.badge)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(SpeakTextStyle.onTintFill))
        }
    }
}
