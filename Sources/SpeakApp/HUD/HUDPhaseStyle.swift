import SpeakCore
import SwiftUI

/// The colour treatment a full-HUD phase gets: one owner for the accent,
/// headline colour, outline weight and background tint, so the shell, glyph
/// and headline cannot drift apart.
struct HUDPhaseStyle: Equatable {
    let phase: HUDPhase

    var color: Color {
        switch phase {
        case .armed:
            return .brandLagoon
        case .recording:
            return .red
        case .transcribing:
            return .brandLagoon
        case .postProcessing:
            return .brandAccent
        case .delivering:
            return .green
        case .editing:
            return .brandAccentWarm
        case .success:
            return .green
        case .failure:
            return .red
        case .hidden:
            return .gray
        }
    }

    var headlineColor: Color {
        switch phase {
        case .failure:
            return color
        default:
            return .primary
        }
    }

    var strokeWidth: CGFloat {
        switch phase {
        case .failure:
            return 2
        default:
            return 1
        }
    }

    /// Opacity of the tint wash behind the content, or `nil` for no wash.
    var tintOpacity: Double? {
        switch phase {
        case .failure:
            return 0.18
        case .postProcessing:
            return 0.06
        default:
            return nil
        }
    }

    @ViewBuilder
    var tint: some View {
        if let tintOpacity {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(color.opacity(tintOpacity))
        }
    }
}
