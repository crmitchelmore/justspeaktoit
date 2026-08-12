import Foundation

// MARK: - Entitlement

/// The lifecycle of a paid subscription, mirroring the server's vocabulary.
///
/// The app never decides this: it is read from the Paid Access service, which
/// derives it from Stripe or the App Store. Treating it as a closed enum means
/// an unknown server value fails loudly rather than being silently read as
/// "entitled".
public enum PaidEntitlementStatus: String, Codable, Sendable, CaseIterable {
    case none
    case trialing
    case active
    case grace
    case pastDue = "past_due"
    case revoked
    case expired

    /// Whether this status, on its own, is one that can unlock paid routing.
    ///
    /// Period expiry is checked separately by ``PaidEntitlement/isActive`` — a
    /// status alone is never sufficient.
    public var permitsAccessWhileInPeriod: Bool {
        switch self {
        case .trialing, .active, .grace:
            return true
        case .none, .pastDue, .revoked, .expired:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "Not subscribed"
        case .trialing: return "Trial"
        case .active: return "Active"
        case .grace: return "Payment issue — access continues"
        case .pastDue: return "Payment overdue"
        case .revoked: return "Cancelled and refunded"
        case .expired: return "Expired"
        }
    }
}

/// How a subscription was purchased.
public enum PaidBillingProvider: String, Codable, Sendable {
    /// Stripe Checkout, used by the direct-download macOS build.
    case stripe
    /// StoreKit 2, used by App Store builds on macOS and iOS.
    case storeKit = "storekit"
    /// Granted manually, e.g. by support.
    case manual

    public var displayName: String {
        switch self {
        case .stripe: return "Card subscription"
        case .storeKit: return "App Store subscription"
        case .manual: return "Granted manually"
        }
    }
}

/// A snapshot of how much of the plan's included usage has been consumed.
public struct PaidUsageSnapshot: Codable, Hashable, Sendable {
    public let period: String
    public let audioSecondsUsed: Int
    public let audioSecondsLimit: Int
    public let tokensUsed: Int
    public let tokensLimit: Int
    public let activeSessions: Int
    public let maxConcurrentSessions: Int

    public init(
        period: String,
        audioSecondsUsed: Int,
        audioSecondsLimit: Int,
        tokensUsed: Int,
        tokensLimit: Int,
        activeSessions: Int,
        maxConcurrentSessions: Int
    ) {
        self.period = period
        self.audioSecondsUsed = audioSecondsUsed
        self.audioSecondsLimit = audioSecondsLimit
        self.tokensUsed = tokensUsed
        self.tokensLimit = tokensLimit
        self.activeSessions = activeSessions
        self.maxConcurrentSessions = maxConcurrentSessions
    }

    /// Fraction of the monthly audio allowance consumed, clamped to `0...1`.
    public var audioFractionUsed: Double {
        guard self.audioSecondsLimit > 0 else { return 0 }
        return min(1, Double(self.audioSecondsUsed) / Double(self.audioSecondsLimit))
    }
}

/// The app's view of a user's paid entitlement.
public struct PaidEntitlement: Codable, Hashable, Sendable {
    public let status: PaidEntitlementStatus
    public let planID: String
    public let provider: PaidBillingProvider
    public let currentPeriodEnd: Date?
    public let cancelAtPeriodEnd: Bool
    /// Server's own verdict, which also accounts for the incident kill switch.
    public let paidRoutingAvailable: Bool
    public let usage: PaidUsageSnapshot?

    public init(
        status: PaidEntitlementStatus,
        planID: String,
        provider: PaidBillingProvider,
        currentPeriodEnd: Date?,
        cancelAtPeriodEnd: Bool,
        paidRoutingAvailable: Bool,
        usage: PaidUsageSnapshot?
    ) {
        self.status = status
        self.planID = planID
        self.provider = provider
        self.currentPeriodEnd = currentPeriodEnd
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.paidRoutingAvailable = paidRoutingAvailable
        self.usage = usage
    }

    /// An entitlement that grants nothing. This is the app's default state, so
    /// a user with no session or no network keeps their own keys and local
    /// models rather than losing dictation.
    public static let unentitled = PaidEntitlement(
        status: .none,
        planID: "free",
        provider: .manual,
        currentPeriodEnd: nil,
        cancelAtPeriodEnd: false,
        paidRoutingAvailable: false,
        usage: nil
    )

    /// Whether the subscription currently grants access, checked against `now`.
    ///
    /// The period end is re-evaluated locally so a cached entitlement cannot
    /// keep paid routing switched on past its expiry while the device is offline.
    public func isActive(asOf now: Date = Date()) -> Bool {
        guard self.status.permitsAccessWhileInPeriod else { return false }
        if let end = self.currentPeriodEnd, end <= now { return false }
        return true
    }

    /// Whether paid routing should be used for this request right now.
    ///
    /// Requires the server to agree as well, so the incident kill switch takes
    /// effect immediately without needing the client to be updated.
    public func allowsPaidRouting(asOf now: Date = Date()) -> Bool {
        self.isActive(asOf: now) && self.paidRoutingAvailable
    }
}

// MARK: - Routing policy

/// The operations that can be routed through the paid service.
public enum PaidOperation: String, Codable, Sendable, CaseIterable {
    case liveTranscription = "live_transcription"
    case batchTranscription = "batch_transcription"
    case postProcessing = "post_processing"

    public var displayName: String {
        switch self {
        case .liveTranscription: return "Live transcription"
        case .batchTranscription: return "Recorded transcription"
        case .postProcessing: return "Transcript cleanup"
        }
    }
}

/// One entry of the server's canonical "Best" policy.
public struct PaidRoute: Codable, Hashable, Sendable {
    public let operation: PaidOperation
    public let provider: String
    /// Catalogue identifier, resolvable through `ModelCatalog.friendlyName(for:)`.
    public let model: String
    public let displayName: String

    public init(operation: PaidOperation, provider: String, model: String, displayName: String) {
        self.operation = operation
        self.provider = provider
        self.model = model
        self.displayName = displayName
    }
}

/// The server-owned routing policy for paid requests.
///
/// The app displays this so a subscriber can see exactly which model is being
/// used, but it cannot change it: model choice on the paid path belongs to the
/// server, which is what makes "Best" a single, auditable decision.
public struct PaidRoutingPolicy: Codable, Hashable, Sendable {
    public let version: String
    public let routes: [PaidRoute]

    public init(version: String, routes: [PaidRoute]) {
        self.version = version
        self.routes = routes
    }

    public func route(for operation: PaidOperation) -> PaidRoute? {
        self.routes.first { $0.operation == operation }
    }

    /// A conservative local fallback used only for display before the first
    /// successful policy fetch. It is never used to make a routing decision.
    public static let unknown = PaidRoutingPolicy(version: "unknown", routes: [])
}

// MARK: - Errors

/// Failures from the paid-access service.
///
/// Every case is recoverable by falling back to the user's own keys or a local
/// model, which is the behaviour the apps implement: paid access is a
/// convenience layer, never a dependency.
public enum PaidAccessError: LocalizedError, Sendable, Equatable {
    case notSignedIn
    case entitlementRequired
    case quotaExceeded
    case tooManySessions
    /// The requested operation has no supported paid route. Deliberately fatal
    /// for the request rather than silently downgraded.
    case unsupportedOperation(PaidOperation)
    case paidRoutingDisabled
    case billingChannelUnavailable(String)
    case serviceUnavailable(statusCode: Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with Apple to use your subscription."
        case .entitlementRequired:
            return "An active subscription is required. Your own API keys and local models still work."
        case .quotaExceeded:
            return "This month's included usage has been used up. Your own API keys and local models still work."
        case .tooManySessions:
            return "Too many recordings are running on your account at once."
        case .unsupportedOperation(let operation):
            return "\(operation.displayName) is not available on the subscription plan."
        case .paidRoutingDisabled:
            return "Subscription routing is temporarily unavailable. Your own API keys and local models still work."
        case .billingChannelUnavailable(let reason):
            return reason
        case .serviceUnavailable(let statusCode):
            return "The subscription service is unavailable (status \(statusCode))."
        case .invalidResponse:
            return "The subscription service returned an unexpected response."
        case .network(let description):
            return description
        }
    }

    /// Whether the app should quietly fall back to bring-your-own keys or a
    /// local model instead of surfacing an error.
    public var permitsSilentFallback: Bool {
        switch self {
        // Running out of included usage is not a failure of the user's own
        // configuration, so the request completes through their own key exactly
        // as the error message promises.
        case .notSignedIn, .entitlementRequired, .paidRoutingDisabled, .serviceUnavailable,
             .network, .quotaExceeded:
            return true
        case .tooManySessions, .unsupportedOperation, .billingChannelUnavailable,
             .invalidResponse:
            return false
        }
    }
}
