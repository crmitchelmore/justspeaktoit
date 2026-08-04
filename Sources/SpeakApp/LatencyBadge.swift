import SpeakCore
import SwiftUI

struct LatencyBadge: View {
  let tier: LatencyTier
  let estimatedMs: Int?

  init(tier: LatencyTier, estimatedMs: Int? = nil) {
    self.tier = tier
    self.estimatedMs = estimatedMs
  }

  init(option: ModelCatalog.Option) {
    self.tier = option.latencyTier
    self.estimatedMs = option.estimatedLatencyMs
  }

  private var badgeColor: Color {
    switch tier {
    case .instant: return .green
    case .fast: return .brandLagoon
    case .medium: return .yellow
    case .slow: return .orange
    }
  }

  private var iconName: String {
    switch tier {
    case .instant: return "bolt.fill"
    case .fast: return "hare.fill"
    case .medium: return "gauge.with.dots.needle.50percent"
    case .slow: return "tortoise.fill"
    }
  }

  private var tooltipText: String {
    var text = tier.displayName
    if let ms = estimatedMs {
      text += " (~\(ms)ms)"
    }
    return text
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: iconName)
        .font(.system(size: 9, weight: .semibold))
      Text(tier.displayName)
        .font(.system(size: 9, weight: .medium))
    }
    .foregroundStyle(badgeColor)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(
      Capsule()
        .fill(badgeColor.opacity(0.15))
    )
    .help(tooltipText)
  }
}

struct LatencyBadgeCompact: View {
  let tier: LatencyTier
  let estimatedMs: Int?
  /// Adds a tinted capsule behind the glyph for legibility on translucent
  /// backdrops (used by the HUD capture-health row).
  let emphasized: Bool

  init(tier: LatencyTier, estimatedMs: Int? = nil, emphasized: Bool = false) {
    self.tier = tier
    self.estimatedMs = estimatedMs
    self.emphasized = emphasized
  }

  init(option: ModelCatalog.Option, emphasized: Bool = false) {
    self.tier = option.latencyTier
    self.estimatedMs = option.estimatedLatencyMs
    self.emphasized = emphasized
  }

  private var badgeColor: Color {
    switch tier {
    case .instant: return .green
    case .fast: return .brandLagoon
    case .medium: return .yellow
    case .slow: return .orange
    }
  }

  private var iconName: String {
    switch tier {
    case .instant: return "bolt.fill"
    case .fast: return "hare.fill"
    case .medium: return "gauge.with.dots.needle.50percent"
    case .slow: return "tortoise.fill"
    }
  }

  private var tooltipText: String {
    var text = tier.displayName
    if let ms = estimatedMs {
      text += " (~\(ms)ms)"
    }
    return text
  }

  var body: some View {
    if emphasized {
      glyph
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
          Capsule()
            .fill(badgeColor.opacity(0.16))
        )
        .help(tooltipText)
    } else {
      glyph
        .help(tooltipText)
    }
  }

  private var glyph: some View {
    Image(systemName: iconName)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(badgeColor)
  }
}

#Preview("Latency Badges") {
  VStack(alignment: .leading, spacing: 16) {
    Text("Full Badges").font(.headline)
    HStack(spacing: 12) {
      LatencyBadge(tier: .instant, estimatedMs: 50)
      LatencyBadge(tier: .fast, estimatedMs: 500)
      LatencyBadge(tier: .medium, estimatedMs: 1500)
      LatencyBadge(tier: .slow, estimatedMs: 3000)
    }

    Divider()

    Text("Compact Badges").font(.headline)
    HStack(spacing: 12) {
      LatencyBadgeCompact(tier: .instant, estimatedMs: 50)
      LatencyBadgeCompact(tier: .fast, estimatedMs: 500)
      LatencyBadgeCompact(tier: .medium, estimatedMs: 1500)
      LatencyBadgeCompact(tier: .slow, estimatedMs: 3000)
    }

    Text("Compact Badges (Emphasized)").font(.headline)
    HStack(spacing: 12) {
      LatencyBadgeCompact(tier: .instant, estimatedMs: 50, emphasized: true)
      LatencyBadgeCompact(tier: .fast, estimatedMs: 500, emphasized: true)
      LatencyBadgeCompact(tier: .medium, estimatedMs: 1500, emphasized: true)
      LatencyBadgeCompact(tier: .slow, estimatedMs: 3000, emphasized: true)
    }
  }
  .padding()
}
