import Foundation
import SpeakCore

/// Native date controls exchange Gregorian calendar days, not UTC timestamps.
public struct DesktopHistoryFilter: Codable, Equatable, Sendable {
    public var models: Set<String>
    public var errorsOnly: Bool
    public var fromDay: String
    public var throughDay: String

    public init(models: Set<String> = [], errorsOnly: Bool = false, fromDay: String = "", throughDay: String = "") {
        self.models = models
        self.errorsOnly = errorsOnly
        self.fromDay = fromDay
        self.throughDay = throughDay
    }

    public static let none = DesktopHistoryFilter()

    public func query(timeZone: TimeZone = .current) throws -> HistorySearchQuery {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try self.day(self.fromDay, calendar: calendar)
        let end = try self.day(self.throughDay, calendar: calendar)
        if let start, let end, start > end {
            throw ValidationError(message: "The end date must be on or after the start date.")
        }
        let range: ClosedRange<Date>?
        if let start, let end {
            range = HistorySearchQuery.normalizedDayRange(from: start, through: end, calendar: calendar)
        } else if let start {
            range = calendar.startOfDay(for: start)...Date(timeIntervalSince1970: .infinity)
        } else if let end {
            range = Date(timeIntervalSince1970: -.infinity)...HistorySearchQuery.normalizedDayRange(
                from: end, through: end, calendar: calendar
            ).upperBound
        } else {
            range = nil
        }
        return HistorySearchQuery(modelIdentifiers: self.models, includeErrorsOnly: self.errorsOnly, dateRange: range)
    }

    public struct ValidationError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { self.message }
        public init(message: String) { self.message = message }
    }

    private func day(_ text: String, calendar: Calendar) throws -> Date? {
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              text.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
              let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
            throw ValidationError(message: "Choose a valid calendar date.")
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else {
            throw ValidationError(message: "Choose a valid calendar date.")
        }
        return date
    }
}
