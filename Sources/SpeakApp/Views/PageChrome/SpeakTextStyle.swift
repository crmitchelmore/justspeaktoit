import SwiftUI

// The single source of truth for page-header typography, text drawn on a
// saturated fill, and truncation. The SwiftLint rules `hand_rolled_on_tint_text`
// and `hand_rolled_page_title` reject literal white text and page-title fonts
// anywhere else in SpeakApp, so a change here reaches every screen.

/// Fonts, colours and truncation rules shared by the page headers.
enum SpeakTextStyle {
    static let pageTitle = Font.largeTitle.bold()
    static let pageSubtitle = Font.headline
    static let stripTitle = Font.subheadline.bold()
    static let chipTitle = Font.caption.weight(.semibold)
    static let chipValue = Font.title3.bold()
    static let compactMetric = Font.caption2.weight(.semibold)
    static let badge = Font.callout.weight(.semibold)

    /// Text and symbols drawn on a saturated fill: hero gradients, prominent
    /// tinted buttons and selected tiles.
    static let onTint = Color.white
    static let onTintSecondary = Color.white.opacity(0.85)
    static let onTintTertiary = Color.white.opacity(0.7)
    /// Chips, fields and capsules sitting on a saturated fill.
    static let onTintFill = Color.white.opacity(0.14)
    static let onTintStroke = Color.white.opacity(0.15)

    /// Shrink single-line text this far before truncating it.
    static let minimumScaleFactor: CGFloat = 0.8

    /// Primary text on a control that has a saturated fill when selected.
    static func primary(onTint isOnTint: Bool) -> Color {
        isOnTint ? onTint : Color.primary
    }

    /// Secondary text on a control that has a saturated fill when selected.
    static func secondary(onTint isOnTint: Bool) -> Color {
        isOnTint ? onTintSecondary : Color.secondary
    }
}

extension View {
    /// Single-line text that shrinks slightly, then truncates at the tail; the
    /// full text stays available as a tooltip.
    func speakSingleLine(fullText: String) -> some View {
        lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(SpeakTextStyle.minimumScaleFactor)
            .speakTooltip(fullText)
    }

    /// Live transcript text: when it overflows, the oldest words go first so
    /// the words being spoken stay visible.
    func speakLiveTranscriptLines(_ lines: Int) -> some View {
        lineLimit(lines)
            .truncationMode(.head)
    }
}
