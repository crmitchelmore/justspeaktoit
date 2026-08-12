import SpeakCore
import SwiftUI

// MARK: - Data Models

/// Latency percentiles for one transcription provider, aggregated over history.
struct ProviderLatencyInsight: Identifiable {
  /// Provider identifier, e.g. "deepgram", "openai", "apple".
  let id: String
  let providerName: String
  let sessionCount: Int
  /// Capture start → first live partial (streaming providers only).
  let firstPartialP50: Int?
  let firstPartialP95: Int?
  /// Stop pressed → final insert complete.
  let stopToFinalP50: Int?
  let stopToFinalP95: Int?
}

/// Provider-independent start latency (hotkey → audio capture running).
struct LatencyOverview {
  let sessionCount: Int
  let captureStartP50: Int?
  let captureStartP95: Int?
}

// MARK: - Aggregation

private struct ProviderLatencyAccumulator {
  var firstPartial: [Int] = []
  var stopToFinal: [Int] = []
  var sessions = 0
}

extension Array where Element == HistoryItem {
  /// Groups measured sessions by transcription provider and computes
  /// p50/p95 for first-partial and stop→final latency.
  func latencyInsightsByProvider() -> [ProviderLatencyInsight] {
    var byProvider: [String: ProviderLatencyAccumulator] = [:]

    for item in self {
      guard let latency = item.latency, latency.hasAnyInterval else { continue }
      guard let provider = item.transcriptionProviderID else { continue }
      var accumulator = byProvider[provider] ?? ProviderLatencyAccumulator()
      accumulator.sessions += 1
      if let value = latency.firstPartialMs { accumulator.firstPartial.append(value) }
      if let value = latency.stopToFinalMs { accumulator.stopToFinal.append(value) }
      byProvider[provider] = accumulator
    }

    return byProvider
      .map { provider, accumulator in
        ProviderLatencyInsight(
          id: provider,
          providerName: Self.providerDisplayName(provider),
          sessionCount: accumulator.sessions,
          firstPartialP50: LatencyPercentiles.p50(of: accumulator.firstPartial),
          firstPartialP95: LatencyPercentiles.p95(of: accumulator.firstPartial),
          stopToFinalP50: LatencyPercentiles.p50(of: accumulator.stopToFinal),
          stopToFinalP95: LatencyPercentiles.p95(of: accumulator.stopToFinal)
        )
      }
      .sorted { $0.sessionCount > $1.sessionCount }
  }

  /// Cold-start percentiles across all measured sessions (provider-independent).
  func latencyOverview() -> LatencyOverview {
    let samples = self.compactMap { $0.latency?.captureStartMs }
    return LatencyOverview(
      sessionCount: samples.count,
      captureStartP50: LatencyPercentiles.p50(of: samples),
      captureStartP95: LatencyPercentiles.p95(of: samples)
    )
  }

  private static func providerDisplayName(_ provider: String) -> String {
    let known = [
      "assemblyai": "AssemblyAI",
      "apple": "Apple Speech",
      "cartesia": "Cartesia",
      "deepgram": "Deepgram",
      "elevenlabs": "ElevenLabs",
      "fluidaudio": "FluidAudio",
      "gladia": "Gladia",
      "groq": "Groq",
      "mistral": "Mistral",
      "modulate": "Modulate",
      "openai": "OpenAI",
      "openrouter": "OpenRouter",
      "revai": "Rev.ai",
      "soniox": "Soniox",
      "speechmatics": "Speechmatics",
      "whisperkit": "WhisperKit",
      "xai": "xAI"
    ]
    return known[provider] ?? provider.capitalized
  }
}

extension HistoryItem {
  /// Provider identifier for the transcription phase of this session, derived
  /// from the model identifier (e.g. "deepgram/nova-3" → "deepgram").
  var transcriptionProviderID: String? {
    let transcriptionPhases: Set<ModelUsagePhase> = [
      .transcriptionLive, .transcriptionBatch, .transcriptionLocal
    ]
    let identifier = modelUsages.first { transcriptionPhases.contains($0.phase) }?.modelIdentifier
      ?? modelsUsed.first
    guard let identifier else { return nil }
    return ModelRouting.family(for: identifier).providerID
  }
}

// MARK: - View

struct LatencyInsightsView: View {
  @Environment(\.appVisualDensity) private var density
  let providers: [ProviderLatencyInsight]
  let overview: LatencyOverview

  var body: some View {
    if providers.isEmpty && overview.sessionCount == 0 {
      emptyState
    } else {
      VStack(alignment: .leading, spacing: density.groupSpacing) {
        overviewRow
        if !providers.isEmpty {
          providerTable
        }
        if !density.isCompact {
          Text("p50 / p95 across measured sessions. First words: capture to first partial. Finish: stop to inserted.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: density.inlineSpacing) {
      Image(systemName: "bolt.badge.clock")
        .font(density.isCompact ? .title3 : .largeTitle)
        .foregroundStyle(.secondary)
      Text("No latency data yet. Metrics are captured from your next recording.")
        .font(density.isCompact ? .caption : .subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: density.isCompact ? 44 : 120)
  }

  private var overviewRow: some View {
    HStack {
      Label("Start (hotkey → audio)", systemImage: "power")
        .font(density.isCompact ? .caption : .subheadline)
      Spacer()
      percentilePair(p50: overview.captureStartP50, p95: overview.captureStartP95)
    }
  }

  private var providerTable: some View {
    VStack(alignment: .leading, spacing: density.inlineSpacing) {
      ForEach(providers) { provider in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(provider.providerName)
              .font(density.isCompact ? .caption.bold() : .subheadline.bold())
            Spacer()
            Text("\(provider.sessionCount) session\(provider.sessionCount == 1 ? "" : "s")")
              .font(density.isCompact ? .caption2 : .caption)
              .foregroundStyle(.secondary)
          }
          metricRow(
            label: "First words",
            p50: provider.firstPartialP50,
            p95: provider.firstPartialP95
          )
          metricRow(
            label: "Finish",
            p50: provider.stopToFinalP50,
            p95: provider.stopToFinalP95
          )
        }
        .padding(density.isCompact ? 5 : 10)
        .background(
          RoundedRectangle(cornerRadius: density.isCompact ? 7 : 12, style: .continuous)
            .fill(Color.accentColor.opacity(0.06))
        )
      }
    }
  }

  @ViewBuilder
  private func metricRow(label: String, p50: Int?, p95: Int?) -> some View {
    if p50 != nil || p95 != nil {
      HStack {
        Text(label)
          .font(density.isCompact ? .caption2 : .caption)
          .foregroundStyle(.secondary)
        Spacer()
        percentilePair(p50: p50, p95: p95)
      }
    }
  }

  private func percentilePair(p50: Int?, p95: Int?) -> some View {
    Text("\(formatted(p50)) / \(formatted(p95))")
      .font(density.isCompact ? .caption2.monospacedDigit() : .caption.monospacedDigit())
      .foregroundStyle(.secondary)
  }

  private func formatted(_ milliseconds: Int?) -> String {
    guard let milliseconds else { return "—" }
    return SessionLatencyMetrics.formattedMilliseconds(milliseconds)
  }
}
