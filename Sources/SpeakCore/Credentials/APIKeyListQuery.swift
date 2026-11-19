import Foundation

/// The status filters every API Keys screen offers. Android mirrors these
/// cases in `ApiKeyStatusFilter.kt`; keep the order and labels in step.
public enum APIKeyStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    /// Keys whose last check failed, or that could not be read.
    case errors
    /// Keys with a saved value ("Set").
    case stored
    /// Keys with nothing saved ("Unset").
    case missing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .errors: return "Errors"
        case .stored: return "Set"
        case .missing: return "Unset"
        }
    }

    public func matches(_ entry: APIKeyListEntry) -> Bool {
        switch self {
        case .all: return true
        case .errors: return entry.hasError
        case .stored: return entry.isStored
        case .missing: return !entry.isStored
        }
    }

    /// One bit per case, in `allCases` order, for each filter `entry` passes.
    /// Native pages filter by testing their selected index against this mask,
    /// so the predicate itself is never reimplemented outside Swift.
    public static func matchMask(for entry: APIKeyListEntry) -> UInt32 {
        allCases.enumerated().reduce(into: UInt32(0)) { mask, item in
            if item.element.matches(entry) { mask |= 1 << UInt32(item.offset) }
        }
    }
}

public enum APIKeySortOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case category
    case status

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .category: return "Category"
        case .status: return "Status"
        }
    }
}

public struct APIKeyListEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let isStored: Bool
    /// The key's last check failed or its saved value could not be read.
    public let hasError: Bool

    public init(id: String, title: String, category: String, isStored: Bool) {
        self.init(id: id, title: title, category: category, isStored: isStored, hasError: false)
    }

    public init(id: String, title: String, category: String, isStored: Bool, hasError: Bool) {
        self.id = id
        self.title = title
        self.category = category
        self.isStored = isStored
        self.hasError = hasError
    }
}

/// What an API Keys screen shows when its filter and search leave no rows.
public struct APIKeyListEmptyState: Equatable, Sendable {
    public let title: String
    public let message: String
    public let systemImage: String
}

public enum APIKeyListQuery {
    public static func apply(
        to entries: [APIKeyListEntry],
        searchText: String,
        status: APIKeyStatusFilter,
        sortOrder: APIKeySortOrder
    ) -> [APIKeyListEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            guard status.matches(entry) else { return false }
            guard !query.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(query)
                || entry.category.localizedCaseInsensitiveContains(query)
        }

        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .name:
                return compare(lhs.title, rhs.title, fallback: lhs.id < rhs.id)
            case .category:
                return compare(
                    lhs.category,
                    rhs.category,
                    fallback: compare(lhs.title, rhs.title, fallback: lhs.id < rhs.id)
                )
            case .status:
                if statusRank(lhs) != statusRank(rhs) { return statusRank(lhs) < statusRank(rhs) }
                return compare(lhs.title, rhs.title, fallback: lhs.id < rhs.id)
            }
        }
    }

    public static func emptyState(status: APIKeyStatusFilter, searchText: String) -> APIKeyListEmptyState {
        let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let suffix = searching ? " Try another search." : ""
        switch status {
        case .all:
            return APIKeyListEmptyState(
                title: "No API Keys", message: "No provider matches your search.", systemImage: "key.slash"
            )
        case .errors:
            return APIKeyListEmptyState(
                title: "No Key Errors", message: "No key failed its last check." + suffix,
                systemImage: "checkmark.seal"
            )
        case .stored:
            return APIKeyListEmptyState(
                title: "No Keys Set", message: "No API key is saved yet." + suffix, systemImage: "key.slash"
            )
        case .missing:
            return APIKeyListEmptyState(
                title: "No Unset Keys", message: "Every provider has a saved key." + suffix,
                systemImage: "checkmark.seal"
            )
        }
    }

    /// Errors first, then saved keys, then keys still to add.
    private static func statusRank(_ entry: APIKeyListEntry) -> Int {
        if entry.hasError { return 0 }
        return entry.isStored ? 1 : 2
    }

    private static func compare(_ lhs: String, _ rhs: String, fallback: @autoclosure () -> Bool) -> Bool {
        let result = lhs.localizedCaseInsensitiveCompare(rhs)
        if result == .orderedSame { return fallback() }
        return result == .orderedAscending
    }
}
