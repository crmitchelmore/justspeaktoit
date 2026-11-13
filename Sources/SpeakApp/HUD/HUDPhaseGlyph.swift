import SwiftUI

/// The pulsing indicator at the top of the full HUD: a warning triangle on
/// failure, a tick on success and a dot for every working phase. It pulses
/// only when `animates` is set (not on legacy rendering or Reduce Motion).
struct HUDPhaseGlyph: View {
    let style: HUDPhaseStyle
    let headline: String
    let animates: Bool

    var body: some View {
        switch style.phase {
        case .failure:
            if animates {
                TimelineView(.animation) { context in
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(style.color.gradient)
                        .scaleEffect(Self.pulseScale(at: context.date, amplitude: 0.35))
                        .shadow(color: style.color.opacity(0.45), radius: 10, x: 0, y: 6)
                        .accessibilityLabel("Error indicator")
                        .accessibilityAddTraits(.isImage)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(style.color)
                    .accessibilityLabel("Error indicator")
                    .accessibilityAddTraits(.isImage)
            }
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(style.color)
                .shadow(color: style.color.opacity(0.3), radius: 6, x: 0, y: 4)
                .accessibilityLabel("Success indicator")
                .accessibilityAddTraits(.isImage)
        default:
            if animates {
                TimelineView(.animation) { context in
                    Circle()
                        .fill(style.color.gradient)
                        .frame(width: 18, height: 18)
                        .scaleEffect(Self.pulseScale(at: context.date, amplitude: 0.4))
                        .shadow(color: style.color.opacity(0.4), radius: 6, x: 0, y: 4)
                        .accessibilityLabel("\(headline) status indicator")
                        .accessibilityAddTraits(.isImage)
                }
            } else {
                Circle()
                    .fill(style.color)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("\(headline) status indicator")
                    .accessibilityAddTraits(.isImage)
            }
        }
    }

    /// A one-second triangle wave from 0.9 up to `0.9 + amplitude / 2` and back.
    static func pulseScale(at date: Date, amplitude: Double) -> Double {
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
        return 0.9 + (progress < 0.5 ? progress : 1 - progress) * amplitude
    }
}
