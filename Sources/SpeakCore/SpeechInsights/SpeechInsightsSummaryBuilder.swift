import Foundation

extension SpeechInsightsEngine {
    /// Derives a display-ready summary from an aggregate.
    ///
    /// `now` anchors "this week" / "this month" windows; tests pass fixed
    /// dates for deterministic results.
    public static func summary(
        for aggregate: SpeechInsightsAggregate,
        now: Date = Date(),
        configuration: SpeechInsightsConfiguration = .default
    ) -> SpeechInsightsSummary {
        SpeechInsightsSummary(
            sessionsAnalyzed: aggregate.processedSessionIDs.count,
            topWords: topTerms(from: aggregate.wordCounts, limit: configuration.topWordLimit),
            topBigrams: topPhrases(
                from: aggregate.bigramCounts,
                configuration: configuration
            ),
            topTrigrams: topPhrases(
                from: aggregate.trigramCounts,
                configuration: configuration
            ),
            fillerRatePer1kWords: ratePer1k(
                count: aggregate.totalFillerCount,
                words: aggregate.totalWordCount
            ),
            topFillers: topTerms(from: aggregate.fillerCounts, limit: configuration.topFillerLimit),
            fillerTrend: fillerTrend(for: aggregate, limit: configuration.fillerTrendWeekLimit),
            pace: paceStats(for: aggregate, configuration: configuration),
            vocabulary: vocabularyStats(for: aggregate, now: now, configuration: configuration),
            trendingTerms: trendingTerms(for: aggregate, now: now, configuration: configuration),
            funStats: funStats(for: aggregate, now: now)
        )
    }

    // MARK: - Pieces

    private static func ratePer1k(count: Int, words: Int) -> Double {
        guard words > 0 else { return 0 }
        return Double(count) / Double(words) * 1000
    }

    /// Deterministic top-N: count descending, then term ascending.
    private static func topTerms(from counts: [String: Int], limit: Int) -> [SpeechInsightsSummary.TermCount] {
        counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(max(0, limit))
            .map { SpeechInsightsSummary.TermCount(term: $0.key, count: $0.value) }
    }

    /// Top phrases with glue filtered out: an n-gram made entirely of
    /// stopwords is dropped ("of the", "and then i") unless it is a known
    /// filler phrase, so "you know" and "sort of" still surface.
    private static func topPhrases(
        from counts: [String: Int],
        configuration: SpeechInsightsConfiguration
    ) -> [SpeechInsightsSummary.TermCount] {
        let fillerPhrases = configuration.multiWordFillerPhrases
        let filtered = counts.filter { gram, _ in
            if fillerPhrases.contains(gram) { return true }
            let tokens = gram.split(separator: " ")
            return !tokens.allSatisfy { configuration.stopwords.contains(String($0)) }
        }
        return topTerms(from: filtered, limit: configuration.topPhraseLimit)
    }

    private static func fillerTrend(
        for aggregate: SpeechInsightsAggregate,
        limit: Int
    ) -> [SpeechInsightsSummary.FillerTrendPoint] {
        var byWeek: [Date: (words: Int, fillers: Int)] = [:]
        for session in aggregate.sessions {
            let week = SpeechInsightsAggregate.weekStart(for: session.startedAt)
            let current = byWeek[week] ?? (0, 0)
            byWeek[week] = (current.words + session.wordCount, current.fillers + session.fillerCount)
        }
        return byWeek
            .sorted { $0.key < $1.key }
            .suffix(max(0, limit))
            .map { week, totals in
                SpeechInsightsSummary.FillerTrendPoint(
                    weekStart: week,
                    totalWords: totals.words,
                    fillerCount: totals.fillers
                )
            }
    }

    private struct WPMBucketBound: Sendable {
        let label: String
        let lower: Double
        let upper: Double
    }

    private static let wpmBucketBounds: [WPMBucketBound] = [
        WPMBucketBound(label: "<60", lower: 0, upper: 60),
        WPMBucketBound(label: "60–89", lower: 60, upper: 90),
        WPMBucketBound(label: "90–119", lower: 90, upper: 120),
        WPMBucketBound(label: "120–149", lower: 120, upper: 150),
        WPMBucketBound(label: "150–179", lower: 150, upper: 180),
        WPMBucketBound(label: "180+", lower: 180, upper: .infinity)
    ]

    private static func paceStats(
        for aggregate: SpeechInsightsAggregate,
        configuration: SpeechInsightsConfiguration
    ) -> SpeechInsightsSummary.PaceStats {
        let values = aggregate.sessions
            .filter { $0.duration >= configuration.minimumSessionDurationForWPM }
            .compactMap(\.wordsPerMinute)
            .sorted()
        guard !values.isEmpty else {
            return SpeechInsightsSummary.PaceStats(
                averageWPM: 0,
                medianWPM: 0,
                distribution: [],
                sessionsMeasured: 0
            )
        }

        let average = values.reduce(0, +) / Double(values.count)
        let median: Double
        if values.count.isMultiple(of: 2) {
            median = (values[values.count / 2 - 1] + values[values.count / 2]) / 2
        } else {
            median = values[values.count / 2]
        }
        let distribution = wpmBucketBounds.map { bucket in
            SpeechInsightsSummary.WPMBucket(
                label: bucket.label,
                lowerBound: bucket.lower,
                count: values.filter { $0 >= bucket.lower && $0 < bucket.upper }.count
            )
        }
        return SpeechInsightsSummary.PaceStats(
            averageWPM: average,
            medianWPM: median,
            distribution: distribution,
            sessionsMeasured: values.count
        )
    }

    private static func vocabularyStats(
        for aggregate: SpeechInsightsAggregate,
        now: Date,
        configuration: SpeechInsightsConfiguration
    ) -> SpeechInsightsSummary.VocabularyStats {
        let weekStart = SpeechInsightsAggregate.weekStart(for: now)
        let currentWeekCounts = aggregate.weeklyWordCounts[
            SpeechInsightsAggregate.weekKey(for: now)
        ] ?? [:]
        let newWords = aggregate.firstSeenByWord
            .filter { $0.value >= weekStart && $0.value <= now }
            .map { word, _ in
                SpeechInsightsSummary.TermCount(term: word, count: currentWeekCounts[word] ?? 1)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.term < rhs.term
            }
            .prefix(max(0, configuration.newWordLimit))
        return SpeechInsightsSummary.VocabularyStats(
            uniqueWords: aggregate.wordCounts.count,
            totalContentWords: aggregate.wordCounts.values.reduce(0, +),
            newWordsThisWeek: Array(newWords)
        )
    }

    private static func trendingTerms(
        for aggregate: SpeechInsightsAggregate,
        now: Date,
        configuration: SpeechInsightsConfiguration
    ) -> [SpeechInsightsSummary.TrendingTerm] {
        let currentKey = SpeechInsightsAggregate.weekKey(for: now)
        let weekStart = SpeechInsightsAggregate.weekStart(for: now)
        guard let previousWeek = SpeechInsightsAggregate.canonicalCalendar.date(
            byAdding: .weekOfYear,
            value: -1,
            to: weekStart
        ) else { return [] }
        let previousKey = SpeechInsightsAggregate.weekKey(for: previousWeek)

        let current = aggregate.weeklyWordCounts[currentKey] ?? [:]
        let previous = aggregate.weeklyWordCounts[previousKey] ?? [:]
        return current
            .compactMap { term, count -> SpeechInsightsSummary.TrendingTerm? in
                guard count >= configuration.minimumTrendingCount else { return nil }
                let before = previous[term] ?? 0
                guard count > before else { return nil }
                return SpeechInsightsSummary.TrendingTerm(
                    term: term,
                    currentWeekCount: count,
                    previousWeekCount: before
                )
            }
            .sorted { lhs, rhs in
                if lhs.delta != rhs.delta { return lhs.delta > rhs.delta }
                if lhs.currentWeekCount != rhs.currentWeekCount {
                    return lhs.currentWeekCount > rhs.currentWeekCount
                }
                return lhs.term < rhs.term
            }
            .prefix(max(0, configuration.trendingTermLimit))
            .map { $0 }
    }

    private static func funStats(
        for aggregate: SpeechInsightsAggregate,
        now: Date
    ) -> SpeechInsightsSummary.FunStats {
        let longest = aggregate.sessions.max { lhs, rhs in
            if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
            return lhs.wordCount < rhs.wordCount
        }

        // Word of the month: current month, falling back to the most recent
        // month with data so the card is never empty on the 1st.
        let currentMonthKey = SpeechInsightsAggregate.monthKey(for: now)
        let monthCounts = aggregate.monthlyWordCounts[currentMonthKey]
            ?? aggregate.monthlyWordCounts
                .filter { $0.key <= currentMonthKey }
                .max { $0.key < $1.key }?.value
        let wordOfTheMonth = monthCounts?
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }?.key

        return SpeechInsightsSummary.FunStats(
            totalWordsAllTime: aggregate.totalWordCount,
            longestSessionDuration: longest?.duration ?? 0,
            longestSessionWordCount: longest?.wordCount ?? 0,
            longestSessionDate: longest?.startedAt,
            wordOfTheMonth: wordOfTheMonth
        )
    }
}
