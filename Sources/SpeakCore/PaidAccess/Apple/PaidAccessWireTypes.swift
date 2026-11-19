import Foundation

// The Worker's JSON bodies, decoded only by PaidAccessHTTPClient.
struct SessionResponse: Decodable {
    let accessToken: String
    let accessTokenExpiresAt: Double
    let refreshToken: String
    let refreshTokenExpiresAt: Double
    let userID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenExpiresAt = "access_token_expires_at"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresAt = "refresh_token_expires_at"
        case userID = "user_id"
    }

    var session: PaidAccessSession {
        PaidAccessSession(
            accessToken: self.accessToken,
            accessTokenExpiresAt: Date(timeIntervalSince1970: self.accessTokenExpiresAt),
            refreshToken: self.refreshToken,
            refreshTokenExpiresAt: Date(timeIntervalSince1970: self.refreshTokenExpiresAt),
            userID: self.userID
        )
    }
}

struct UsagePayload: Decodable {
    let period: String
    let audioSecondsUsed: Int
    let audioSecondsLimit: Int
    let tokensUsed: Int
    let tokensLimit: Int
    let activeSessions: Int
    let maxConcurrentSessions: Int
    let audioSecondsMeasured: Int?
    let audioSecondsHeld: Int?
    let tokensMeasured: Int?
    let tokensHeld: Int?

    enum CodingKeys: String, CodingKey {
        case period
        case audioSecondsUsed = "audio_seconds_used"
        case audioSecondsLimit = "audio_seconds_limit"
        case tokensUsed = "tokens_used"
        case tokensLimit = "tokens_limit"
        case activeSessions = "active_sessions"
        case maxConcurrentSessions = "max_concurrent_sessions"
        case audioSecondsMeasured = "audio_seconds_measured"
        case audioSecondsHeld = "audio_seconds_held"
        case tokensMeasured = "tokens_measured"
        case tokensHeld = "tokens_held"
    }

    var snapshot: PaidUsageSnapshot {
        PaidUsageSnapshot(
            period: self.period,
            audioSecondsUsed: self.audioSecondsUsed,
            audioSecondsLimit: self.audioSecondsLimit,
            tokensUsed: self.tokensUsed,
            tokensLimit: self.tokensLimit,
            activeSessions: self.activeSessions,
            maxConcurrentSessions: self.maxConcurrentSessions,
            audioSecondsMeasured: self.audioSecondsMeasured,
            audioSecondsHeld: self.audioSecondsHeld,
            tokensMeasured: self.tokensMeasured,
            tokensHeld: self.tokensHeld
        )
    }
}

struct RoutePayload: Decodable {
    let operation: String
    let provider: String
    let model: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case operation
        case provider
        case model
        case displayName = "display_name"
    }

    var route: PaidRoute? {
        guard let operation = PaidOperation(rawValue: self.operation) else { return nil }
        return PaidRoute(
            operation: operation,
            provider: self.provider,
            model: self.model,
            displayName: self.displayName
        )
    }
}

struct PolicyPayload: Decodable {
    let version: String
    let routes: [RoutePayload]

    var policy: PaidRoutingPolicy {
        // Unknown operations are dropped rather than guessed at, so a newer
        // server cannot make an older client route work it does not understand.
        PaidRoutingPolicy(version: self.version, routes: self.routes.compactMap(\.route))
    }
}

/// Internal rather than private so the tests can cover the one guarantee
/// that matters here: an entitlement and the policy it was issued with are
/// decoded from a single payload, and therefore committed together.
struct EntitlementResponse: Decodable {
    let status: String
    let planID: String
    let source: String
    let currentPeriodEnd: Double?
    let cancelAtPeriodEnd: Bool
    let paidRoutingAvailable: Bool
    let usage: UsagePayload?
    let policy: PolicyPayload?

    enum CodingKeys: String, CodingKey {
        case status
        case planID = "plan_id"
        case source
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case paidRoutingAvailable = "paid_routing_available"
        case usage
        case policy
    }

    var entitlement: PaidEntitlement {
        PaidEntitlement(
            // An unrecognised status is treated as no entitlement rather than
            // being optimistically accepted.
            status: PaidEntitlementStatus(rawValue: self.status) ?? .none,
            planID: self.planID,
            provider: PaidBillingProvider(rawValue: self.source) ?? .manual,
            currentPeriodEnd: self.currentPeriodEnd.map { Date(timeIntervalSince1970: $0) },
            cancelAtPeriodEnd: self.cancelAtPeriodEnd,
            paidRoutingAvailable: self.paidRoutingAvailable,
            usage: self.usage?.snapshot
        )
    }

    /// A response without a policy yields ``PaidRoutingPolicy/unknown`` rather
    /// than an error: the entitlement is still worth publishing, and a router
    /// with no routes falls the request back to the user's own configuration.
    var state: PaidAccessState {
        PaidAccessState(
            entitlement: self.entitlement,
            policy: self.policy?.policy ?? .unknown
        )
    }
}

struct StoreKitSyncResponse: Decodable {
    let status: String
    let active: Bool
    let currentPeriodEnd: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case active
        case currentPeriodEnd = "current_period_end"
    }

    var entitlement: PaidEntitlement {
        PaidEntitlement(
            status: PaidEntitlementStatus(rawValue: self.status) ?? .none,
            planID: "paid",
            provider: .storeKit,
            currentPeriodEnd: self.currentPeriodEnd.map { Date(timeIntervalSince1970: $0) },
            cancelAtPeriodEnd: false,
            paidRoutingAvailable: self.active,
            usage: nil
        )
    }
}

struct CheckoutResponse: Decodable {
    let checkoutURL: String

    enum CodingKeys: String, CodingKey {
        case checkoutURL = "checkout_url"
    }
}

struct PortalResponse: Decodable {
    let portalURL: String

    enum CodingKeys: String, CodingKey {
        case portalURL = "portal_url"
    }
}

struct TextResponse: Decodable {
    let text: String
    let model: String
    let provider: String
}
