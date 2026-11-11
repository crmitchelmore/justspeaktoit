import Foundation

public enum HUDExpansionPreference: String, CaseIterable, Identifiable, Sendable {
    case compact
    case expanded
    case autoExpand

    public var id: String { rawValue }
    public static let defaultValue: Self = .autoExpand
    public static let autoExpandThreshold = 100

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .expanded: return "Always Expanded"
        case .autoExpand: return "Auto-Expand"
        }
    }

    public func expanded(previous: Bool, transcriptCount: Int) -> Bool {
        switch self {
        case .compact: return false
        case .expanded: return true
        case .autoExpand: return previous || transcriptCount > Self.autoExpandThreshold
        }
    }
}
