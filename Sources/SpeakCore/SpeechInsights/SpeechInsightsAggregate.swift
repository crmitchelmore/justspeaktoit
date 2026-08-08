import Foundation

/// Persisted, incrementally-updatable rollup of every analysed session.
///
/// The aggregate is the source of truth the dashboard reads from: it can be
/// updated with just the sessions recorded since the last visit, so opening
/// the dashboard stays instant even with tens of thousands of history items.
/// A full recompute over the same sessions produces an identical aggregate
/// (verified by tests), which is what makes retention-driven deletions safe:
/// when previously processed sessions disappear from history the engine simply
/// rebuilds from what remains.
///
/// Everything in here is derived from local history only. It is never added to
/// any sync payload and never leaves the device.
public struct SpeechInsightsAggregate: Codable, Sendable, Equatable {
    /// Bump when the stored shape changes; loaders discard mismatched data
    /// and recompute from history.
    public static let currentSchemaVersion = 1

    /// Compact per-session stats retained for time-based metrics (WPM
    /// distribution, filler trend, longest session). Kept sorted by
    /// `(startedAt, id)` so aggregates built in different orders compare equal.
    public struct SessionStat: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let startedAt: Date
        public let duration: TimeInterval
        public let wordCount: Int
        public let fillerCount: Int

        public init(
            id: UUID,
            startedAt: Date,
            duration: TimeInterval,
            wordCount: Int,
            fillerCount: Int
        ) {
            self.id = id
            self.startedAt = startedAt
            self.duration = duration
            self.wordCount = wordCount
            self.fillerCount = fillerCount
        }

        /// Words per minute, or `nil` when the session has no usable duration.
        public var wordsPerMinute: Double? {
            guard duration > 0, wordCount > 0 else { return nil }
            return Double(wordCount) / (duration / 60)
        }
    }

    public var schemaVersion: Int
    /// IDs of every session folded into this aggregate.
    public var processedSessionIDs: Set<UUID>
    /// Total spoken words (all surface tokens, fillers included).
    public var totalWordCount: Int
    /// Total filler-phrase occurrences.
    public var totalFillerCount: Int
    /// Occurrences per filler phrase.
    public var fillerCounts: [String: Int]
    /// Lemmatized, stopword- and filler-filtered content-word counts.
    public var wordCounts: [String: Int]
    /// Raw (surface-token) bigram and trigram counts, space-joined.
    public var bigramCounts: [String: Int]
    public var trigramCounts: [String: Int]
    /// Content-word counts bucketed by canonical week key ("yyyy-MM-dd").
    public var weeklyWordCounts: [String: [String: Int]]
    /// Content-word counts bucketed by canonical month key ("yyyy-MM").
    public var monthlyWordCounts: [String: [String: Int]]
    /// Earliest session date each content word was seen in.
    public var firstSeenByWord: [String: Date]
    /// Per-session stats, sorted by `(startedAt, id)`.
    public var sessions: [SessionStat]

    public init() {
        schemaVersion = Self.currentSchemaVersion
        processedSessionIDs = []
        totalWordCount = 0
        totalFillerCount = 0
        fillerCounts = [:]
        wordCounts = [:]
        bigramCounts = [:]
        trigramCounts = [:]
        weeklyWordCounts = [:]
        monthlyWordCounts = [:]
        firstSeenByWord = [:]
        sessions = []
    }

    public var isEmpty: Bool { processedSessionIDs.isEmpty }

    // MARK: - Canonical calendar bucketing

    /// Fixed Gregorian/UTC calendar with ISO weeks (Monday start) used for all
    /// bucketing. A stable calendar keeps persisted week keys valid regardless
    /// of the device's current locale or timezone.
    public static let canonicalCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// Start of the canonical week containing `date`.
    public static func weekStart(for date: Date) -> Date {
        canonicalCalendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// Canonical week key ("yyyy-MM-dd" of the week's start) for `date`.
    public static func weekKey(for date: Date) -> String {
        let parts = canonicalCalendar.dateComponents([.year, .month, .day], from: weekStart(for: date))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Canonical month key ("yyyy-MM") for `date`.
    public static func monthKey(for date: Date) -> String {
        let parts = canonicalCalendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Parses a canonical week key back into the week-start date.
    public static func date(fromWeekKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return canonicalCalendar.date(from: components)
    }
}
