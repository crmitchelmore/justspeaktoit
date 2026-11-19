import Charts
import SpeakCore
import SwiftUI

// MARK: - Cards

struct SpeechTopWordsCard: View {
  @Environment(\.appVisualDensity) private var density
  let summary: SpeechInsightsSummary

  var body: some View {
    SpeakDensityCard(title: "Top Words", systemImage: "textformat.abc", tint: Color.brandAccent) {
      let words = Array(summary.topWords.prefix(density.isCompact ? 5 : 8))
      if words.isEmpty {
        SpeechEmptyHint(text: "No content words yet")
      } else {
        VStack(alignment: .leading, spacing: density.inlineSpacing) {
          let maxCount = words.first?.count ?? 1
          ForEach(words) { word in
            SpeechTermRow(term: word.term, count: word.count, maxCount: maxCount, tint: .brandAccent)
          }
        }
      }
    }
    .speakTooltip("Your most-spoken words across all raw transcripts, minus common filler and glue words.")
  }
}

struct SpeechTopPhrasesCard: View {
  @Environment(\.appVisualDensity) private var density
  let summary: SpeechInsightsSummary

  var body: some View {
    SpeakDensityCard(title: "Top Phrases", systemImage: "text.quote", tint: Color.brandLagoon) {
      let phrases = Array(summary.topBigrams.prefix(density.isCompact ? 3 : 5))
        + Array(summary.topTrigrams.prefix(density.isCompact ? 2 : 3))
      if phrases.isEmpty {
        SpeechEmptyHint(text: "No repeated phrases yet")
      } else {
        VStack(alignment: .leading, spacing: density.inlineSpacing) {
          let maxCount = phrases.map(\.count).max() ?? 1
          ForEach(phrases) { phrase in
            SpeechTermRow(
              term: "\u{201C}\(phrase.term)\u{201D}",
              count: phrase.count,
              maxCount: maxCount,
              tint: .brandLagoon
            )
          }
        }
      }
    }
    .speakTooltip("Two- and three-word phrases you repeat the most across your dictation sessions.")
  }
}

struct SpeechVocabularyCard: View {
  @Environment(\.appVisualDensity) private var density
  let summary: SpeechInsightsSummary

  var body: some View {
    SpeakDensityCard(title: "Vocabulary", systemImage: "character.book.closed", tint: Color.brandAccentDeep) {
      VStack(alignment: .leading, spacing: density.groupSpacing) {
        HStack(spacing: density.groupSpacing) {
          SpeechMiniStat(
            title: "Unique Words",
            value: summary.vocabulary.uniqueWords.formatted()
          )
          SpeechMiniStat(
            title: "Richness",
            value: summary.vocabulary.richness.formatted(
              .percent.precision(.fractionLength(0))
            )
          )
        }
        if !summary.vocabulary.newWordsThisWeek.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("New this week".uppercased())
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(
              summary.vocabulary.newWordsThisWeek
                .prefix(density.isCompact ? 4 : 8)
                .map(\.term)
                .joined(separator: " · ")
            )
            .font(density.isCompact ? .caption : .callout)
            .lineLimit(2)
          }
        }
        if !summary.trendingTerms.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("Trending".uppercased())
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(summary.trendingTerms.prefix(density.isCompact ? 2 : 3)) { term in
              HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(.green)
                Text(term.term)
                  .font(density.isCompact ? .caption : .callout)
                Spacer()
                Text("\(term.previousWeekCount) → \(term.currentWeekCount)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
    .speakTooltip("How broad your spoken vocabulary is, plus words that are new or trending this week.")
  }
}

struct SpeechFillerCard: View {
  @Environment(\.appVisualDensity) private var density
  let summary: SpeechInsightsSummary

  var body: some View {
    SpeakDensityCard(
      title: "Filler Words",
      systemImage: "waveform.badge.exclamationmark",
      tint: Color.brandAccentWarm
    ) {
      VStack(alignment: .leading, spacing: density.inlineSpacing) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(summary.fillerRatePer1kWords.formatted(.number.precision(.fractionLength(1))))
            .font(density.isCompact ? .caption.bold() : .title2.bold())
            .foregroundStyle(Color.brandAccentWarm)
          Text("per 1k words")
            .font(density.isCompact ? .caption2 : .caption)
            .foregroundStyle(.secondary)
          Spacer()
        }

        if summary.fillerTrend.count > 1 {
          Chart(summary.fillerTrend) { point in
            LineMark(
              x: .value("Week", point.weekStart, unit: .weekOfYear),
              y: .value("Fillers per 1k", point.ratePer1kWords)
            )
            .foregroundStyle(Color.brandAccentWarm)
            .interpolationMethod(.catmullRom)
            AreaMark(
              x: .value("Week", point.weekStart, unit: .weekOfYear),
              y: .value("Fillers per 1k", point.ratePer1kWords)
            )
            .foregroundStyle(Color.brandAccentWarm.opacity(0.15).gradient)
            .interpolationMethod(.catmullRom)
          }
          .chartYAxis {
            AxisMarks(position: .leading)
          }
          .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
              if let date = value.as(Date.self) {
                AxisValueLabel {
                  Text(date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                }
              }
            }
          }
          .frame(height: density.chartHeight)
        }

        if !summary.topFillers.isEmpty, !density.isCompact {
          Text(
            summary.topFillers
              .map { "\($0.term) ×\($0.count)" }
              .joined(separator: "   ")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }
    }
    .speakTooltip("How often um, uh, and other fillers appear per 1,000 spoken words, and how that trends.")
  }
}

struct SpeechPaceCard: View {
  @Environment(\.appVisualDensity) private var density
  let summary: SpeechInsightsSummary

  var body: some View {
    SpeakDensityCard(title: "Speaking Pace", systemImage: "speedometer", tint: Color.brandLagoonDeep) {
      if summary.pace.sessionsMeasured == 0 {
        SpeechEmptyHint(text: "Longer sessions are needed to measure pace")
      } else {
        VStack(alignment: .leading, spacing: density.inlineSpacing) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(summary.pace.averageWPM.formatted(.number.precision(.fractionLength(0))))
              .font(density.isCompact ? .caption.bold() : .title2.bold())
              .foregroundStyle(Color.brandLagoonDeep)
            Text("words/min average")
              .font(density.isCompact ? .caption2 : .caption)
              .foregroundStyle(.secondary)
            Spacer()
            if !density.isCompact {
              Text("median \(summary.pace.medianWPM.formatted(.number.precision(.fractionLength(0))))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Chart(summary.pace.distribution) { bucket in
            BarMark(
              x: .value("Pace", bucket.label),
              y: .value("Sessions", bucket.count)
            )
            .foregroundStyle(Color.brandLagoonDeep.gradient)
          }
          .chartYAxis {
            AxisMarks(position: .leading)
          }
          .frame(height: density.chartHeight)

          if !density.isCompact {
            Text("Sessions by words-per-minute range")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .speakTooltip("How fast you dictate, session by session. Conversational speech is usually 120–160 wpm.")
  }
}

struct SpeechFunStatsCard: View {
  @Environment(\.appVisualDensity) private var density
  let summary: SpeechInsightsSummary

  var body: some View {
    SpeakDensityCard(title: "Speech Records", systemImage: "trophy", tint: Color.brandAccent) {
      VStack(alignment: .leading, spacing: density.groupSpacing) {
        HStack(spacing: density.groupSpacing) {
          SpeechMiniStat(
            title: "Words All-Time",
            value: summary.funStats.totalWordsAllTime.formatted()
          )
          SpeechMiniStat(
            title: "Sessions Analyzed",
            value: summary.sessionsAnalyzed.formatted()
          )
        }
        HStack(spacing: density.groupSpacing) {
          SpeechMiniStat(
            title: "Longest Session",
            value: formattedLongestSession
          )
          SpeechMiniStat(
            title: "Word of the Month",
            value: summary.funStats.wordOfTheMonth ?? "—"
          )
        }
      }
    }
    .speakTooltip("Bragging rights: lifetime word count, your marathon session, and this month's signature word.")
  }

  private var formattedLongestSession: String {
    let duration = summary.funStats.longestSessionDuration
    guard duration > 0 else { return "—" }
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%02dm %02ds", minutes, seconds)
  }
}

// MARK: - Shared pieces

struct SpeechTermRow: View {
  @Environment(\.appVisualDensity) private var density
  let term: String
  let count: Int
  let maxCount: Int
  let tint: Color

  var body: some View {
    HStack(spacing: density.inlineSpacing) {
      Text(term)
        .font(density.isCompact ? .caption : .callout)
        .lineLimit(1)
      Spacer(minLength: 8)
      GeometryReader { proxy in
        Capsule()
          .fill(tint.opacity(0.25))
          .frame(width: max(6, proxy.size.width * ratio), height: 6)
          .frame(maxHeight: .infinity, alignment: .center)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .frame(width: density.isCompact ? 40 : 72)
      Text("\(count)")
        .font(density.isCompact ? .caption2.monospacedDigit() : .caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 28, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(term), \(count) times")
  }

  private var ratio: CGFloat {
    guard maxCount > 0 else { return 0 }
    return CGFloat(count) / CGFloat(maxCount)
  }
}

struct SpeechMiniStat: View {
  @Environment(\.appVisualDensity) private var density
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: density.isCompact ? 1 : 6) {
      Text(title)
        .font(density.isCompact ? .caption2 : .caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(value)
        .font(density.isCompact ? .caption.bold() : .title3.bold())
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(density.isCompact ? 5 : 16)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 7 : 20, style: .continuous)
        .fill(Color.accentColor.opacity(0.08))
    )
  }
}

struct SpeechEmptyHint: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
