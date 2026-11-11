import SpeakCore
import SwiftUI

/// This month's synthesised characters and cost.
struct DashboardVoiceOutputUsageCard: View {
  @EnvironmentObject private var environment: AppEnvironment
  @Environment(\.appVisualDensity) private var density

  var body: some View {
    DashboardCard(title: "Voice Output Usage", systemImage: "speaker.wave.3", tint: Color.brandLagoonDeep) {
      VStack(alignment: .leading, spacing: density.inlineSpacing) {
        let totalCharacters = environment.tts.totalCharactersThisMonth()
        let totalCost = environment.tts.totalCostThisMonth()

        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Characters This Month")
              .font(density.isCompact ? .caption2 : .caption)
              .foregroundStyle(.secondary)
            Text("\(totalCharacters)")
              .font(density.isCompact ? .caption.bold() : .title2.bold())
              .foregroundStyle(Color.brandLagoonDeep)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text("Total Cost")
              .font(density.isCompact ? .caption2 : .caption)
              .foregroundStyle(.secondary)
            Text("$\(totalCost, format: .number.precision(.fractionLength(2)))")
              .font(density.isCompact ? .caption.bold() : .title2.bold())
              .foregroundStyle(Color.brandLagoonDeep)
          }
        }

        if totalCharacters > 0, !density.isCompact {
          Text(
            "\(totalCharacters) characters synthesized this month"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else if !density.isCompact {
          Text("No voice output generated yet this month")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .speakTooltip("Track your text-to-speech usage and costs this month.")
  }
}

/// This month's synthesised characters per TTS provider.
struct DashboardTTSProvidersCard: View {
  @EnvironmentObject private var environment: AppEnvironment
  @Environment(\.appVisualDensity) private var density

  var body: some View {
    DashboardCard(title: "TTS Providers", systemImage: "waveform.circle", tint: Color.brandAccent) {
      let now = Date()
      let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: now)!
      let usage = environment.tts.usageByProvider(since: monthAgo)

      if usage.isEmpty {
        VStack(spacing: density.inlineSpacing) {
          Image(systemName: "speaker.wave.2.circle")
            .font(density.isCompact ? .title3 : .largeTitle)
            .foregroundStyle(.secondary)
          Text("No TTS usage yet")
            .font(density.isCompact ? .caption : .subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: density.isCompact ? 44 : 120)
      } else {
        VStack(alignment: .leading, spacing: density.inlineSpacing) {
          ForEach(usage.sorted(by: { $0.value > $1.value }), id: \.key) { provider, count in
            HStack {
              Circle()
                .fill(providerColor(provider))
                .frame(width: density.isCompact ? 7 : 12, height: density.isCompact ? 7 : 12)
              Text(provider.displayName)
                .font(density.isCompact ? .caption : .subheadline)
              Spacer()
              Text("\(count) chars")
                .font(density.isCompact ? .caption2.monospacedDigit() : .subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .speakTooltip("See which TTS providers you use most frequently.")
  }

  // One branch per provider; the switch is the whole body.
  // swiftlint:disable:next cyclomatic_complexity
  private func providerColor(_ provider: TTSProvider) -> Color {
    switch provider {
    case .elevenlabs: return .brandAccent
    case .openai: return .green
    case .openrouter: return .indigo
    case .azure: return .brandLagoonDeep
    case .deepgram: return .brandAccentWarm
    case .soniox: return .brandLagoon
    case .cartesia: return .purple
    case .groq: return .orange
    case .gemini: return .blue
    case .mistral: return .indigo
    case .speechmatics: return .cyan
    case .xai: return .primary
    case .system: return .gray
    }
  }
}
