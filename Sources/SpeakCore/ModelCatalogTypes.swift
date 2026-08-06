import Foundation

// MARK: - LatencyTier

public enum LatencyTier: String, Codable, CaseIterable, Comparable, Sendable {
    case instant
    case fast
    case medium
    case slow

    public var displayName: String {
        switch self {
        case .instant: return "Instant"
        case .fast: return "Fast"
        case .medium: return "Medium"
        case .slow: return "Slow"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .instant: return 0
        case .fast: return 1
        case .medium: return 2
        case .slow: return 3
        }
    }

    public static func < (lhs: LatencyTier, rhs: LatencyTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - ModelCatalog shared nested types (kept in dedicated file for maintainability)

public extension ModelCatalog {
    enum Tag: String, Codable, CaseIterable, Hashable, Sendable {
        case fast
        case cheap
        case quality
        case leading
        case privacy

        public var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .cheap: return "Cheap"
            case .quality: return "Quality"
            case .leading: return "Leading"
            case .privacy: return "Private"
            }
        }
    }

    struct Pricing: Hashable, Sendable {
        /// Dollars per 1M input tokens.
        public let promptPerMTokens: Double
        /// Dollars per 1M output tokens.
        public let completionPerMTokens: Double

        public init(promptPerMTokens: Double, completionPerMTokens: Double) {
            self.promptPerMTokens = promptPerMTokens
            self.completionPerMTokens = completionPerMTokens
        }

        public var compactDisplay: String {
            "\(Self.formatDollars(promptPerMTokens))/\(Self.formatDollars(completionPerMTokens))"
        }

        public var displayName: String {
            "\(compactDisplay) / 1M"
        }

        private static func formatDollars(_ value: Double) -> String {
            if value >= 10 { return String(format: "$%.0f", value) }
            if value >= 0.1 { return String(format: "$%.2f", value) }
            if value > 0 { return String(format: "$%.3f", value) }
            return "$0"
        }
    }

    struct Option: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
        public let description: String?
        public let estimatedLatencyMs: Int?
        public let latencyTier: LatencyTier
        public let tags: [Tag]
        public let pricing: Pricing?
        public let contextLength: Int?

        public init(
            id: String,
            displayName: String,
            description: String? = nil,
            estimatedLatencyMs: Int? = nil,
            latencyTier: LatencyTier = .medium,
            tags: [Tag] = [],
            pricing: Pricing? = nil,
            contextLength: Int? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.description = description
            self.estimatedLatencyMs = estimatedLatencyMs
            self.latencyTier = latencyTier
            self.tags = tags
            self.pricing = pricing
            self.contextLength = contextLength
        }
    }
}
