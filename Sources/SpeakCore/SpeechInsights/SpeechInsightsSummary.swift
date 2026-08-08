import Foundation

/// Display-ready snapshot derived from a `SpeechInsightsAggregate`.
/// Everything is a plain value; the UI layer renders it without further work.
public struct SpeechInsightsSummary: Sendable, Equatable {
    public struct TermCount: Sendable, Equatable, Identifiable {
        public let term: String
        public let count: Int

        public init(term: String, count: Int) {
            self.term = term
            self.count = count
        }

        public var id: String { term }
    }

    public struct TrendingTerm: Sendable, Equatable, Identifiable {
        public let term: String
        public let currentWeekCount: Int
        public let previousWeekCount: Int

        public init(term: String, currentWeekCount: Int, previousWeekCount: Int) {
            self.term = term
            self.currentWeekCount = currentWeekCount
            self.previousWeekCount = previousWeekCount
        }

        public var id: String { term }
        public var delta: Int { currentWeekCount - previousWeekCount }
    }

    public struct FillerTrendPoint: Sendable, Equatable, Identifiable {
        public let weekStart: Date
        public let totalWords: Int
        public let fillerCount: Int

        public init(weekStart: Date, totalWords: Int, fillerCount: Int) {
            self.weekStart = weekStart
            self.totalWords = totalWords
            self.fillerCount = fillerCount
        }

        public var id: Date { weekStart }

        /// Fillers per 1,000 spoken words for the week.
        public var ratePer1kWords: Double {
            guard totalWords > 0 else { return 0 }
            return Double(fillerCount) / Double(totalWords) * 1000
        }
    }

    public struct WPMBucket: Sendable, Equatable, Identifiable {
        public let label: String
        public let lowerBound: Double
        public let count: Int

        public init(label: String, lowerBound: Double, count: Int) {
            self.label = label
            self.lowerBound = lowerBound
            self.count = count
        }

        public var id: Double { lowerBound }
    }

    public struct PaceStats: Sendable, Equatable {
        public let averageWPM: Double
        public let medianWPM: Double
        public let distribution: [WPMBucket]
        public let sessionsMeasured: Int

        public init(
            averageWPM: Double,
            medianWPM: Double,
            distribution: [WPMBucket],
            sessionsMeasured: Int
        ) {
            self.averageWPM = averageWPM
            self.medianWPM = medianWPM
            self.distribution = distribution
            self.sessionsMeasured = sessionsMeasured
        }
    }

    public struct VocabularyStats: Sendable, Equatable {
        /// Distinct content words (lemmatized, stopwords excluded) all-time.
        public let uniqueWords: Int
        /// Total content-word occurrences all-time.
        public let totalContentWords: Int
        /// Content words first spoken during the current week, busiest first.
        public let newWordsThisWeek: [TermCount]

        public init(uniqueWords: Int, totalContentWords: Int, newWordsThisWeek: [TermCount]) {
            self.uniqueWords = uniqueWords
            self.totalContentWords = totalContentWords
            self.newWordsThisWeek = newWordsThisWeek
        }

        /// Type–token ratio: unique content words over total content words.
        public var richness: Double {
            guard totalContentWords > 0 else { return 0 }
            return Double(uniqueWords) / Double(totalContentWords)
        }
    }

    public struct FunStats: Sendable, Equatable {
        public let totalWordsAllTime: Int
        public let longestSessionDuration: TimeInterval
        public let longestSessionWordCount: Int
        public let longestSessionDate: Date?
        public let wordOfTheMonth: String?

        public init(
            totalWordsAllTime: Int,
            longestSessionDuration: TimeInterval,
            longestSessionWordCount: Int,
            longestSessionDate: Date?,
            wordOfTheMonth: String?
        ) {
            self.totalWordsAllTime = totalWordsAllTime
            self.longestSessionDuration = longestSessionDuration
            self.longestSessionWordCount = longestSessionWordCount
            self.longestSessionDate = longestSessionDate
            self.wordOfTheMonth = wordOfTheMonth
        }
    }

    public let sessionsAnalyzed: Int
    public let topWords: [TermCount]
    public let topBigrams: [TermCount]
    public let topTrigrams: [TermCount]
    /// Fillers per 1,000 spoken words, all-time.
    public let fillerRatePer1kWords: Double
    public let topFillers: [TermCount]
    public let fillerTrend: [FillerTrendPoint]
    public let pace: PaceStats
    public let vocabulary: VocabularyStats
    public let trendingTerms: [TrendingTerm]
    public let funStats: FunStats

    public init(
        sessionsAnalyzed: Int,
        topWords: [TermCount],
        topBigrams: [TermCount],
        topTrigrams: [TermCount],
        fillerRatePer1kWords: Double,
        topFillers: [TermCount],
        fillerTrend: [FillerTrendPoint],
        pace: PaceStats,
        vocabulary: VocabularyStats,
        trendingTerms: [TrendingTerm],
        funStats: FunStats
    ) {
        self.sessionsAnalyzed = sessionsAnalyzed
        self.topWords = topWords
        self.topBigrams = topBigrams
        self.topTrigrams = topTrigrams
        self.fillerRatePer1kWords = fillerRatePer1kWords
        self.topFillers = topFillers
        self.fillerTrend = fillerTrend
        self.pace = pace
        self.vocabulary = vocabulary
        self.trendingTerms = trendingTerms
        self.funStats = funStats
    }
}
