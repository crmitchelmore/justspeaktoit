import Foundation

/// Cross-platform projection used for history search, filtering and statistics.
/// Platform history records can retain richer persistence details while sharing
/// the behaviour users expect on Mac and iPhone.
public struct HistoryPresentationItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let rawTranscription: String?
    public let processedTranscription: String?
    public let modelIdentifiers: [String]
    public let recordingDuration: TimeInterval
    public let cost: Decimal
    public let errorCount: Int
    public let originPlatform: String

    public init(
        id: UUID,
        createdAt: Date,
        rawTranscription: String?,
        processedTranscription: String?,
        modelIdentifiers: [String],
        recordingDuration: TimeInterval,
        cost: Decimal = 0,
        errorCount: Int = 0,
        originPlatform: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscription = rawTranscription
        self.processedTranscription = processedTranscription
        self.modelIdentifiers = modelIdentifiers
        self.recordingDuration = recordingDuration
        self.cost = cost
        self.errorCount = errorCount
        self.originPlatform = originPlatform
    }

    public var bestTranscription: String? {
        let processed = processedTranscription?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let processed, !processed.isEmpty { return processed }
        let raw = rawTranscription?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    public var wordCount: Int {
        bestTranscription?.split(whereSeparator: \.isWhitespace).count ?? 0
    }
}

public struct HistorySearchQuery: Equatable, Sendable {
    public var searchText: String?
    public var modelIdentifiers: Set<String>
    public var includeErrorsOnly: Bool
    public var dateRange: ClosedRange<Date>?

    public init(
        searchText: String? = nil,
        modelIdentifiers: Set<String> = [],
        includeErrorsOnly: Bool = false,
        dateRange: ClosedRange<Date>? = nil
    ) {
        self.searchText = searchText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.modelIdentifiers = modelIdentifiers
        self.includeErrorsOnly = includeErrorsOnly
        self.dateRange = dateRange
    }

    public static let none = HistorySearchQuery()

    /// Expands two user-selected dates into an inclusive, daylight-saving-safe day range.
    public static func normalizedDayRange(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar = .current
    ) -> ClosedRange<Date> {
        let lower = calendar.startOfDay(for: startDate)
        let endStart = calendar.startOfDay(for: max(startDate, endDate))
        let upper = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endStart) ?? endStart
        return lower...upper
    }

    /// Returns whether an entry satisfies every active search and filter constraint.
    public func matches(_ item: HistoryPresentationItem) -> Bool {
        if let term = searchText, !term.isEmpty {
            let transcriptMatches = item.rawTranscription?.lowercased().contains(term) == true
                || item.processedTranscription?.lowercased().contains(term) == true
            let modelMatches = item.modelIdentifiers.contains { identifier in
                identifier.lowercased().contains(term)
                    || ModelCatalog.friendlyName(for: identifier).lowercased().contains(term)
            }
            guard transcriptMatches || modelMatches else { return false }
        }

        if !modelIdentifiers.isEmpty {
            let requested = Set(modelIdentifiers.map { $0.lowercased() })
            let actual = Set(item.modelIdentifiers.map { $0.lowercased() })
            guard !requested.isDisjoint(with: actual) else { return false }
        }

        if includeErrorsOnly, item.errorCount == 0 { return false }
        if let dateRange, !dateRange.contains(item.createdAt) { return false }
        return true
    }
}

public struct HistoryPresentationStatistics: Equatable, Sendable {
    public let totalSessions: Int
    public let cumulativeRecordingDuration: TimeInterval
    public let totalSpend: Decimal
    public let averageSessionLength: TimeInterval
    public let sessionsWithErrors: Int
    public let totalWords: Int

    /// Aggregates all user-facing history metrics in one pass over the supplied entries.
    public init(items: [HistoryPresentationItem]) {
        var duration: TimeInterval = 0
        var spend: Decimal = 0
        var errorSessions = 0
        var words = 0
        for item in items {
            duration += max(0, item.recordingDuration)
            spend += item.cost
            if item.errorCount > 0 { errorSessions += 1 }
            words += item.wordCount
        }

        totalSessions = items.count
        cumulativeRecordingDuration = duration
        totalSpend = spend
        averageSessionLength = items.isEmpty ? 0 : duration / Double(items.count)
        sessionsWithErrors = errorSessions
        totalWords = words
    }
}
