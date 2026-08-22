import SpeakCore
import SwiftUI

// MARK: - Data Models

/// Percentiles of one latency interval together with how many sessions
/// measured it. Not every session measures every interval (batch sessions
/// have no partials, failed sessions stop part-way), so the count travels
/// with the percentiles rather than being inferred from the session count.
struct LatencyDistribution: Equatable {
  let sampleCount: Int
  let p50: Int?
  let p95: Int?

  init(samples: [Int]) {
    self.sampleCount = samples.count
    self.p50 = LatencyPercentiles.p50(of: samples)
    self.p95 = LatencyPercentiles.p95(of: samples)
  }
}

/// Latency percentiles for one transcription provider, aggregated over history.
struct ProviderLatencyInsight: Identifiable {
  /// Provider identifier, e.g. "deepgram", "openai", "apple".
  let id: String
  let providerName: String
  let sessionCount: Int
  /// Capture start → first live partial (streaming providers only).
  let firstPartial: LatencyDistribution
  /// Capture start → first character visible in the target app. Streaming
  /// sessions measure their first live insert; one-shot sessions measure the
  /// final paste, so both kinds contribute a sample (issue #611).
  let firstInsert: LatencyDistribution
  /// Stop pressed → final insert complete.
  let stopToFinal: LatencyDistribution
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
  var firstInsert: [Int] = []
  var stopToFinal: [Int] = []
  var sessions = 0
}

extension Array where Element == HistoryItem {
  /// Groups measured sessions by transcription provider and computes
  /// p50/p95 (with sample counts) for first-partial, first-insert and
  /// stop→final latency.
  func latencyInsightsByProvider() -> [ProviderLatencyInsight] {
    var byProvider: [String: ProviderLatencyAccumulator] = [:]

    for item in self {
      guard let latency = item.latency, latency.hasAnyInterval else { continue }
      guard let provider = item.transcriptionProviderID else { continue }
      var accumulator = byProvider[provider] ?? ProviderLatencyAccumulator()
      accumulator.sessions += 1
      if let value = latency.firstPartialMs { accumulator.firstPartial.append(value) }
      if let value = latency.firstInsertMs { accumulator.firstInsert.append(value) }
      if let value = latency.stopToFinalMs { accumulator.stopToFinal.append(value) }
      byProvider[provider] = accumulator
    }

    return byProvider
      .map { provider, accumulator in
        ProviderLatencyInsight(
          id: provider,
          providerName: Self.providerDisplayName(provider),
          sessionCount: accumulator.sessions,
          firstPartial: LatencyDistribution(samples: accumulator.firstPartial),
          firstInsert: LatencyDistribution(samples: accumulator.firstInsert),
          stopToFinal: LatencyDistribution(samples: accumulator.stopToFinal)
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
          Text(
            "p50 / p95 across measured sessions (sample count beside each row). "
              + "First words: capture to first partial. First insert: capture to first visible character. "
              + "Finish: stop to inserted."
          )
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
    HStack(spacing: density.inlineSpacing) {
      Label("Start (hotkey → audio)", systemImage: "power")
        .font(density.isCompact ? .caption : .subheadline)
      if overview.sessionCount > 0 {
        Text("×\(overview.sessionCount)")
          .font((density.isCompact ? Font.caption2 : Font.caption).monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      Spacer()
      percentilePair(p50: overview.captureStartP50, p95: overview.captureStartP95)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Start, hotkey to audio: p50 \(formatted(overview.captureStartP50)), "
        + "p95 \(formatted(overview.captureStartP95)), "
        + "\(overview.sessionCount) sample\(overview.sessionCount == 1 ? "" : "s")"
    )
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
          metricRow(label: "First words", distribution: provider.firstPartial)
          metricRow(label: "First insert", distribution: provider.firstInsert)
          metricRow(label: "Finish", distribution: provider.stopToFinal)
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
  private func metricRow(label: String, distribution: LatencyDistribution) -> some View {
    if distribution.sampleCount > 0 {
      HStack(spacing: density.inlineSpacing) {
        Text(label)
          .font(density.isCompact ? .caption2 : .caption)
          .foregroundStyle(.secondary)
        Text("×\(distribution.sampleCount)")
          .font((density.isCompact ? Font.caption2 : Font.caption).monospacedDigit())
          .foregroundStyle(.tertiary)
        Spacer()
        percentilePair(p50: distribution.p50, p95: distribution.p95)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(label): p50 \(formatted(distribution.p50)), p95 \(formatted(distribution.p95)), "
          + "\(distribution.sampleCount) sample\(distribution.sampleCount == 1 ? "" : "s")"
      )
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
