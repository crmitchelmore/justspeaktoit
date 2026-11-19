import SpeakCore
import SwiftUI

/// Capability tags (fast, cheap, quality…) shown beside a model.
struct ModelTagBadges: View {
  let tags: [ModelCatalog.Tag]
  let compact: Bool

  var body: some View {
    if tags.isEmpty {
      EmptyView()
    } else {
      HStack(spacing: 6) {
        ForEach(tags.prefix(compact ? 2 : tags.count), id: \.self) { tag in
          Text(tag.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tagForegroundColor(tag))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              Capsule(style: .continuous)
                .fill(tagBackgroundColor(tag))
            )
        }
      }
    }
  }

  private func tagBackgroundColor(_ tag: ModelCatalog.Tag) -> Color {
    switch tag {
    case .fast: return Color.brandLagoon.opacity(0.12)
    case .cheap: return Color.green.opacity(0.14)
    case .quality: return Color.brandAccent.opacity(0.12)
    case .leading: return Color.brandAccentWarm.opacity(0.14)
    case .privacy: return Color.brandLagoon.opacity(0.14)
    }
  }

  private func tagForegroundColor(_ tag: ModelCatalog.Tag) -> Color {
    switch tag {
    case .fast: return .brandLagoon
    case .cheap: return .green
    case .quality: return .brandAccent
    case .leading: return .brandAccentWarm
    case .privacy: return .brandLagoon
    }
  }
}

/// Context length and price for a model that publishes them.
struct ModelPricingBadges: View {
  let option: ModelCatalog.Option
  let compact: Bool

  var body: some View {
    if let pricing = option.pricing {
      HStack(spacing: 8) {
        if !compact, let contextLength = option.contextLength {
          Text(ModelContextLength.label(contextLength))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Text(pricing.compactDisplay)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Short context-window label, e.g. "128k ctx" or "1M ctx".
enum ModelContextLength {
  static func label(_ contextLength: Int) -> String {
    if contextLength >= 1_000_000 {
      return "\(Int(Double(contextLength) / 1_000_000.0))M ctx"
    }
    return "\(Int(Double(contextLength) / 1_000.0))k ctx"
  }
}
