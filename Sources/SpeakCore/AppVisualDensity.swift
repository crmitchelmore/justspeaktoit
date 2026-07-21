import SwiftUI

/// A user-selected presentation density shared by the macOS and iOS apps.
/// Normal intentionally preserves the existing spacing; compact reduces
/// whitespace without shrinking interactive controls below platform norms.
public enum AppVisualDensity: String, CaseIterable, Identifiable, Sendable {
    case normal
    case compact

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .compact: return "Compact"
        }
    }

    public var sectionSpacing: CGFloat { self == .compact ? 12 : 20 }
    public var pagePadding: CGFloat { self == .compact ? 14 : 24 }
    public var cardPadding: CGFloat { self == .compact ? 15 : 24 }
    public var cardContentSpacing: CGFloat { self == .compact ? 11 : 18 }
    public var listRowVerticalPadding: CGFloat { self == .compact ? 1 : 4 }
    public var minimumListRowHeight: CGFloat { self == .compact ? 38 : 44 }
    public var listSectionSpacing: CGFloat { self == .compact ? 12 : 24 }
}

private struct AppVisualDensityKey: EnvironmentKey {
    static let defaultValue = AppVisualDensity.normal
}

public extension EnvironmentValues {
    var appVisualDensity: AppVisualDensity {
        get { self[AppVisualDensityKey.self] }
        set { self[AppVisualDensityKey.self] = newValue }
    }
}

public enum APIKeyStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case stored
    case missing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All Keys"
        case .stored: return "Stored"
        case .missing: return "Missing"
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

    public init(id: String, title: String, category: String, isStored: Bool) {
        self.id = id
        self.title = title
        self.category = category
        self.isStored = isStored
    }
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
            let matchesStatus: Bool
            switch status {
            case .all: matchesStatus = true
            case .stored: matchesStatus = entry.isStored
            case .missing: matchesStatus = !entry.isStored
            }
            guard matchesStatus else { return false }
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
                if lhs.isStored != rhs.isStored { return lhs.isStored && !rhs.isStored }
                return compare(lhs.title, rhs.title, fallback: lhs.id < rhs.id)
            }
        }
    }

    private static func compare(_ lhs: String, _ rhs: String, fallback: @autoclosure () -> Bool) -> Bool {
        let result = lhs.localizedCaseInsensitiveCompare(rhs)
        if result == .orderedSame { return fallback() }
        return result == .orderedAscending
    }
}
