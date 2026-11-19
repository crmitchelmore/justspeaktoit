import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// A user-selected presentation density shared by the macOS and iOS apps.
/// Normal intentionally preserves the existing spacing. Compact is a distinct
/// information-dense layout that removes decorative whitespace, favours inline
/// presentation, and keeps touch targets at platform minimums.
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

    public var isCompact: Bool { self == .compact }

    public var sectionSpacing: CGFloat { isCompact ? 6 : 20 }
    public var pagePadding: CGFloat { isCompact ? 8 : 24 }
    public var cardPadding: CGFloat { isCompact ? 8 : 24 }
    public var cardContentSpacing: CGFloat { isCompact ? 6 : 18 }
    public var inlineSpacing: CGFloat { isCompact ? 6 : 12 }
    public var groupSpacing: CGFloat { isCompact ? 8 : 16 }
    public var listRowVerticalPadding: CGFloat { isCompact ? 0 : 4 }
    public var listSectionSpacing: CGFloat { isCompact ? 4 : 24 }
    public var cardCornerRadius: CGFloat { isCompact ? 12 : 28 }
    public var gridMinimumWidth: CGFloat { isCompact ? 240 : 340 }
    public var chartHeight: CGFloat { isCompact ? 132 : 200 }

    /// Returns the number of columns that can usefully fit in a settings canvas.
    /// Normal mode deliberately remains single-column; compact mode turns spare
    /// horizontal space into additional information density.
    public func adaptiveColumnCount(
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat = 340,
        maximumColumns: Int = 3
    ) -> Int {
        guard isCompact else { return 1 }

        let safeMaximum = max(1, maximumColumns)
        let safeMinimum = max(1, minimumColumnWidth)
        if availableWidth.isNaN { return 1 }
        guard availableWidth.isFinite else { return safeMaximum }
        let safeWidth = max(0, availableWidth)
        let count = Int((safeWidth + sectionSpacing) / (safeMinimum + sectionSpacing))
        return min(safeMaximum, max(1, count))
    }

    public var minimumListRowHeight: CGFloat {
        #if os(iOS)
        // Compact iOS rows remove internal whitespace but retain Apple's
        // minimum comfortable touch target.
        44
        #else
        isCompact ? 30 : 44
        #endif
    }

    #if canImport(SwiftUI)
    public func prefersInlineLayout(dynamicTypeSize: DynamicTypeSize) -> Bool {
        isCompact && !dynamicTypeSize.isAccessibilitySize
    }
    #endif
}

#if canImport(SwiftUI)
private struct AppVisualDensityKey: EnvironmentKey {
    static let defaultValue = AppVisualDensity.normal
}

public extension EnvironmentValues {
    var appVisualDensity: AppVisualDensity {
        get { self[AppVisualDensityKey.self] }
        set { self[AppVisualDensityKey.self] = newValue }
    }
}
#endif
