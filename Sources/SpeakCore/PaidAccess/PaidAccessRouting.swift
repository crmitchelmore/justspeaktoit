import Foundation

// MARK: - Billing channel policy

/// Which billing rail a build must use.
///
/// This is a store-policy decision, not a preference: App Store builds have to
/// transact through StoreKit, and the direct-download Mac build cannot. Keeping
/// it here — next to ``DistributionChannel`` — means neither platform can drift,
/// and the Worker enforces the same rule independently so a modified client
/// cannot route around it.
public enum PaidBillingChannel: String, Sendable, Equatable {
    case stripeCheckout
    case storeKit

    public var provider: PaidBillingProvider {
        switch self {
        case .stripeCheckout: return .stripe
        case .storeKit: return .storeKit
        }
    }

    /// Copy for the primary purchase button.
    public var purchaseActionTitle: String {
        switch self {
        case .stripeCheckout: return "Subscribe with card"
        case .storeKit: return "Subscribe"
        }
    }

    /// Copy for the manage/cancel affordance.
    public var manageActionTitle: String {
        switch self {
        case .stripeCheckout: return "Manage billing"
        case .storeKit: return "Manage subscription"
        }
    }

    /// Whether the purchase flow leaves the app for a web page.
    public var opensExternalBrowser: Bool {
        self == .stripeCheckout
    }
}

public extension DistributionChannel {
    /// The billing rail this build must use for paid access.
    var paidBillingChannel: PaidBillingChannel {
        switch self {
        case .direct: return .stripeCheckout
        case .appStore: return .storeKit
        }
    }
}

// MARK: - Simple model choices

/// Whether the model-selection interface should be shown.
///
/// Issue #648 asks for subscribers to be able to switch model pickers off
/// entirely and simply get the best available option. Encoding that as a policy
/// type — rather than an `if` in each view — keeps the rule uniform across the
/// two platforms' very different settings screens, and keeps it testable.
public struct SimpleModelChoicesPolicy: Sendable, Equatable {
    /// The user's preference for hiding model selection.
    public let isEnabled: Bool
    /// Whether paid routing is actually available right now.
    public let hasPaidRouting: Bool

    public init(isEnabled: Bool, hasPaidRouting: Bool) {
        self.isEnabled = isEnabled
        self.hasPaidRouting = hasPaidRouting
    }

    /// Whether model pickers should be hidden.
    ///
    /// Hiding only applies while paid routing is genuinely available. Without
    /// that condition a lapsed subscriber would be left with no model pickers
    /// *and* no paid routing, unable to dictate at all.
    public var hidesModelSelection: Bool {
        self.isEnabled && self.hasPaidRouting
    }

    /// Explanation shown wherever model selection has been hidden. It always
    /// states that local models and personal API keys remain available, because
    /// that is the honest description of what the subscription is for.
    public var explanation: String {
        if self.hidesModelSelection {
            return "Simple model choices is on, so Speak picks the best model for each task. "
                + "Turn it off to choose models yourself, or to go back to your own API keys "
                + "or on-device models at any time."
        }
        if self.isEnabled {
            return "Simple model choices applies while your subscription is active. "
                + "Choose your models below in the meantime."
        }
        return "Choose the model for each task, or turn on Simple model choices "
            + "to let your subscription pick the best one."
    }
}

// MARK: - Routing decision

/// Where a single request should be executed.
public enum PaidRoutingDecision: Sendable, Equatable {
    /// Send to the paid service; vendor credentials stay on the server.
    case paidService(PaidRoute)
    /// Use the user's own API key for the given catalogue model.
    case bringYourOwnKey(model: String)
    /// Run on device.
    case localModel(model: String)

    public var usesPaidService: Bool {
        if case .paidService = self { return true }
        return false
    }

    /// The catalogue identifier that will actually be used, for display and History.
    public var effectiveModelID: String {
        switch self {
        case .paidService(let route): return route.model
        case .bringYourOwnKey(let model): return model
        case .localModel(let model): return model
        }
    }
}

/// Decides, per request, whether to use the paid service or the user's own
/// setup.
///
/// The defaults matter more than the logic: without a verified entitlement this
/// always returns the user's existing configuration, so adding paid access
/// cannot change behaviour for anyone who has not subscribed.
public struct PaidAccessRouter: Sendable {
    private let entitlement: PaidEntitlement
    private let policy: PaidRoutingPolicy
    private let isPaidRoutingPreferred: Bool

    public init(
        entitlement: PaidEntitlement,
        policy: PaidRoutingPolicy,
        isPaidRoutingPreferred: Bool
    ) {
        self.entitlement = entitlement
        self.policy = policy
        self.isPaidRoutingPreferred = isPaidRoutingPreferred
    }

    /// Resolves a routing decision.
    ///
    /// - Parameters:
    ///   - operation: The work to be done.
    ///   - configuredModel: The model the user has selected for this operation.
    ///   - now: Injected clock, so entitlement expiry is testable.
    /// - Throws: ``PaidAccessError/unsupportedOperation(_:)`` when paid routing
    ///   is requested for an operation the server publishes no route for. This
    ///   is deliberately an error: silently using a different model than the one
    ///   advertised would make "Best" meaningless.
    public func decide(
        for operation: PaidOperation,
        configuredModel: String,
        now: Date = Date()
    ) throws -> PaidRoutingDecision {
        let isLocal = ModelRouting.family(for: configuredModel).isDownloadedLocal
            || AppleLocalModels.isAppleSpeechModel(configuredModel)

        guard self.isPaidRoutingPreferred, self.entitlement.allowsPaidRouting(asOf: now) else {
            return isLocal
                ? .localModel(model: configuredModel)
                : .bringYourOwnKey(model: configuredModel)
        }

        guard let route = self.policy.route(for: operation) else {
            throw PaidAccessError.unsupportedOperation(operation)
        }
        return .paidService(route)
    }
}
