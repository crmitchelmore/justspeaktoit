#if os(iOS)
import Charts
import SpeakCore
import SwiftUI

/// Usage insights computed on this device from History: the usage totals the History header shows,
/// plus SpeakCore's speech insights (words, phrases, fillers, pace and records), the same numbers
/// the Mac dashboard shows for the same history. Nothing is sent anywhere; the aggregate lives in
/// Application Support and is never synced.
struct UsageInsightsView: View {
    @ObservedObject private var historyManager = iOSHistoryManager.shared
    @StateObject private var insights = SpeechInsightsModel(storageURL: Self.storageURL)

    var body: some View {
        List {
            usageSection
            if let summary = insights.summary, summary.sessionsAnalyzed > 0 {
                wordsSection(summary)
                phrasesSection(summary)
                vocabularySection(summary)
                fillerSection(summary)
                paceSection(summary)
                recordsSection(summary)
            } else if insights.isComputing || historyManager.isLoading {
                Section {
                    ProgressView("Analysing your speech…")
                        .accessibilityIdentifier("usageInsightsProgress")
                }
            } else {
                Section {
                    Text("Dictate something and your speech insights appear here.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("usageInsightsEmptyState")
                }
            }
        }
        .navigationTitle("Usage insights")
        .accessibilityIdentifier("usageInsightsView")
        .task { await historyManager.loadIfNeededAndWait() }
        .onReceive(historyManager.$items) { items in
            insights.refresh(records: Self.records(from: items))
        }
    }

    /// History entries with text, analysed on their raw transcripts.
    static func records(from items: [iOSHistoryItem]) -> [SpeechSessionRecord] {
        items.compactMap { SpeechSessionRecord(historyRecord: $0.historyRecord) }
    }

    private static var storageURL: URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return SpeechInsightsModel.storageURL(inSupportDirectory: support, fileManager: fileManager)
    }

    // MARK: - Usage

    private var usageSection: some View {
        let statistics = HistoryPresentationStatistics(items: historyManager.items.map(\.presentationItem))
        return Section {
            row("Sessions", "\(statistics.totalSessions)", id: "usageInsightsSessions")
            row("Errors", "\(statistics.sessionsWithErrors)", id: "usageInsightsErrors")
            row(
                "Recording time", Self.duration(statistics.cumulativeRecordingDuration),
                id: "usageInsightsRecordingTime"
            )
            row("Average length", Self.duration(statistics.averageSessionLength), id: "usageInsightsAverageLength")
            row("Words", "\(statistics.totalWords)", id: "usageInsightsWords")
        } header: {
            Text("Usage")
        } footer: {
            Text("Worked out on \(DeviceCopy.thisDevice) from your History. Nothing leaves \(DeviceCopy.yourDevice).")
        }
    }

    // MARK: - Speech insights

    private func wordsSection(_ summary: SpeechInsightsSummary) -> some View {
        Section("Top words") {
            terms(summary.topWords.prefix(10), id: "usageInsightsTopWords", empty: "No words yet")
        }
    }

    private func phrasesSection(_ summary: SpeechInsightsSummary) -> some View {
        Section("Top phrases") {
            terms(
                summary.topBigrams.prefix(5) + summary.topTrigrams.prefix(3),
                id: "usageInsightsTopPhrases", empty: "No repeated phrases yet"
            )
        }
    }

    private func vocabularySection(_ summary: SpeechInsightsSummary) -> some View {
        Section("Vocabulary") {
            row("Unique words", "\(summary.vocabulary.uniqueWords)", id: "usageInsightsUniqueWords")
            row(
                "Richness", summary.vocabulary.richness.formatted(.percent.precision(.fractionLength(0))),
                id: "usageInsightsRichness"
            )
            if !summary.vocabulary.newWordsThisWeek.isEmpty {
                row(
                    "New this week",
                    summary.vocabulary.newWordsThisWeek.prefix(5).map(\.term).joined(separator: ", "),
                    id: "usageInsightsNewWords"
                )
            }
            ForEach(summary.trendingTerms.prefix(5)) { term in
                row(
                    "Trending: \(term.term)", "\(term.previousWeekCount) → \(term.currentWeekCount)",
                    id: "usageInsightsTrending.\(term.term)"
                )
            }
        }
    }

    private func fillerSection(_ summary: SpeechInsightsSummary) -> some View {
        Section("Filler words") {
            row(
                "Per 1k words", summary.fillerRatePer1kWords.formatted(.number.precision(.fractionLength(1))),
                id: "usageInsightsFillerRate"
            )
            terms(summary.topFillers, id: "usageInsightsTopFillers", empty: "No filler words")
            if summary.fillerTrend.count > 1 {
                Chart(summary.fillerTrend) { point in
                    LineMark(
                        x: .value("Week", point.weekStart, unit: .weekOfYear),
                        y: .value("Per 1k words", point.ratePer1kWords)
                    )
                    .interpolationMethod(.monotone)
                }
                .frame(height: 120)
                .accessibilityLabel("Filler words per 1,000 words by week")
                .accessibilityIdentifier("usageInsightsFillerTrend")
            }
        }
    }

    private func paceSection(_ summary: SpeechInsightsSummary) -> some View {
        Section {
            if summary.pace.sessionsMeasured == 0 {
                Text("Record for at least 10 seconds to measure your pace.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("usageInsightsPaceEmpty")
            } else {
                row("Average", Self.wordsPerMinute(summary.pace.averageWPM), id: "usageInsightsAverageWPM")
                row("Median", Self.wordsPerMinute(summary.pace.medianWPM), id: "usageInsightsMedianWPM")
                ForEach(summary.pace.distribution) { bucket in
                    row(
                        "\(bucket.label) words/min", "\(bucket.count)",
                        id: "usageInsightsPace.\(Int(bucket.lowerBound))"
                    )
                }
            }
        } header: {
            Text("Speaking pace")
        } footer: {
            if summary.pace.sessionsMeasured > 0 {
                Text("From \(summary.pace.sessionsMeasured) sessions of 10 seconds or more.")
            }
        }
    }

    private func recordsSection(_ summary: SpeechInsightsSummary) -> some View {
        Section("Speech records") {
            row("Words all-time", "\(summary.funStats.totalWordsAllTime)", id: "usageInsightsWordsAllTime")
            row("Sessions analysed", "\(summary.sessionsAnalyzed)", id: "usageInsightsSessionsAnalysed")
            row(
                "Longest session", Self.duration(summary.funStats.longestSessionDuration),
                id: "usageInsightsLongestSession"
            )
            if let word = summary.funStats.wordOfTheMonth {
                row("Word of the month", word, id: "usageInsightsWordOfTheMonth")
            }
        }
    }

    // MARK: - Rows

    private func row(_ title: String, _ value: String, id: String) -> some View {
        LabeledContent(title, value: value)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func terms(
        _ terms: some Collection<SpeechInsightsSummary.TermCount>, id: String, empty: String
    ) -> some View {
        if terms.isEmpty {
            Text(empty).foregroundStyle(.secondary).accessibilityIdentifier("\(id).empty")
        } else {
            ForEach(Array(terms)) { term in
                row(term.term, "\(term.count)", id: "\(id).\(term.term)")
            }
        }
    }

    /// The History header's duration format, so the two screens read the same.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    private static func wordsPerMinute(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) words/min"
    }
}
#endif
