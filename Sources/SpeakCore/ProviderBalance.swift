import Foundation

/// What a balance figure is counted in.
///
/// Providers publish very different meters — Deepgram bills a dollar wallet,
/// Rev.ai hands out transcription seconds, ElevenLabs meters characters — so a
/// balance is never just a number. `other` keeps a vendor's own wording rather
/// than guessing a unit the API did not promise.
public enum ProviderBalanceUnit: Sendable, Equatable {
    case characters
    case seconds
    case minutes
    case requests
    case credits
    case other(String)

    public var displayName: String {
        switch self {
        case .characters: return "characters"
        case .seconds: return "seconds"
        case .minutes: return "minutes"
        case .requests: return "requests"
        case .credits: return "credits"
        case .other(let name): return name
        }
    }
}

/// A money figure with the currency the provider reported it in. The currency
/// is never assumed: a provider that omits it produces `unknown`, not dollars.
public struct ProviderBalanceMoney: Sendable, Equatable {
    public let amount: Decimal
    public let currencyCode: String

    public init(amount: Decimal, currencyCode: String) {
        self.amount = amount
        self.currencyCode = currencyCode.uppercased()
    }
}

/// What a provider account currently holds.
///
/// This is deliberately a typed state rather than an optional number. The
/// difference between "you have $4.10 of credit", "you have 30,000 characters
/// left this month", "you have spent $4.10 so far" and "we could not tell" is
/// the whole point of the screen, and collapsing them into `Double?` is how a
/// missing limit ends up rendered as unlimited credit.
public enum ProviderBalanceState: Sendable, Equatable {
    /// Prepaid money the account can spend. Only for providers that document a
    /// wallet endpoint — usage and cost reports are never this case.
    case cash(ProviderBalanceMoney)

    /// A metered entitlement that depletes. `total` is `nil` when the provider
    /// did not publish a limit; that is a missing limit, never an unlimited one.
    case allowance(remaining: Double, total: Double?, unit: ProviderBalanceUnit)

    /// Consumption the provider reports with no wallet meaning attached —
    /// admin usage and cost reports live here. Rendered as usage, never as a
    /// balance the user can spend.
    case usage(spent: ProviderBalanceMoney?, quantity: Double?, unit: ProviderBalanceUnit?, note: String)

    /// A free tier's remaining allowance.
    case freeQuota(remaining: Double?, total: Double?, unit: ProviderBalanceUnit)

    /// Metered post-paid billing: there is no stored value to deplete.
    case payAsYouGo(note: String)

    /// The provider publishes no balance contract this app can read.
    case unavailable(reason: String)

    /// The balance could not be determined — auth failure, quota failure,
    /// cancellation, a malformed response, or a field the provider omitted.
    case unknown(reason: String)

    /// Whether this state may be presented to the user as spendable credit.
    /// Usage, quota, pay-as-you-go, unavailable and unknown never may.
    public var isSpendableCredit: Bool {
        switch self {
        case .cash, .allowance: return true
        case .usage, .freeQuota, .payAsYouGo, .unavailable, .unknown: return false
        }
    }
}

/// One account's balance as of one refresh.
///
/// Keyed by account rather than by credential: an account whose single key
/// powers both transcription and voice output is fetched and shown once.
public struct ProviderBalanceSnapshot: Sendable, Equatable, Identifiable {
    public let accountID: String
    public let providerDisplayName: String
    public let state: ProviderBalanceState
    /// When this figure was read from the provider.
    public let refreshedAt: Date
    /// When the allowance next resets, where the API reports one.
    public let resetsAt: Date?
    /// When the balance itself expires, where the API reports one.
    public let expiresAt: Date?
    /// The plan or tier name the provider reported, where it reports one.
    public let planName: String?

    public var id: String { accountID }

    public init(
        accountID: String,
        providerDisplayName: String,
        state: ProviderBalanceState,
        refreshedAt: Date,
        resetsAt: Date? = nil,
        expiresAt: Date? = nil,
        planName: String? = nil
    ) {
        self.accountID = accountID
        self.providerDisplayName = providerDisplayName
        self.state = state
        self.refreshedAt = refreshedAt
        self.resetsAt = resetsAt
        self.expiresAt = expiresAt
        self.planName = planName
    }
}

// MARK: - Presentation

/// Renders a balance state as user-facing text.
///
/// Kept out of the views so macOS and iOS read identically and so the wording
/// rules — above all that a missing limit reads as unknown — are testable.
public enum ProviderBalanceFormatter {
    /// The headline figure, for example `$4.10 credit` or `29,000 of 30,000 characters left`.
    public static func summary(for state: ProviderBalanceState) -> String {
        switch state {
        case .cash(let money):
            return "\(formatMoney(money)) credit"
        case .allowance(let remaining, let total, let unit):
            return allowanceSummary(remaining: remaining, total: total, unit: unit, label: "left")
        case .usage(let spent, let quantity, let unit, _):
            if let spent {
                return "\(formatMoney(spent)) used"
            }
            if let quantity, let unit {
                return "\(number(quantity)) \(unit.displayName) used"
            }
            return "Usage reported"
        case .freeQuota(let remaining, let total, let unit):
            guard let remaining else {
                return total.map { "Free tier of \(number($0)) \(unit.displayName)" } ?? "Free tier"
            }
            return allowanceSummary(remaining: remaining, total: total, unit: unit, label: "left on the free tier")
        case .payAsYouGo:
            return "Pay as you go"
        case .unavailable:
            return "No balance to show"
        case .unknown:
            return "Balance unknown"
        }
    }

    /// The explanatory second line, or `nil` when the summary says it all.
    public static func detail(for state: ProviderBalanceState) -> String? {
        switch state {
        case .cash:
            return nil
        case .allowance(_, let total, _):
            // A provider that omits the limit tells us nothing about how much
            // is left in total, and silence must not read as unlimited.
            return total == nil ? "The provider did not report a limit, so the total is unknown." : nil
        case .usage(_, _, _, let note):
            return note
        case .freeQuota(_, let total, _):
            return total == nil ? "The provider did not report a quota, so the total is unknown." : nil
        case .payAsYouGo(let note):
            return note
        case .unavailable(let reason):
            return reason
        case .unknown(let reason):
            return reason
        }
    }

    /// `Checked 2 minutes ago`, appended beneath the figure so a stale number
    /// is never mistaken for a live one.
    public static func refreshDescription(
        for snapshot: ProviderBalanceSnapshot,
        now: Date = Date()
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: snapshot.refreshedAt, relativeTo: now))"
    }

    /// `Resets 1 October 2026`, where the provider reported a reset or expiry.
    public static func scheduleDescription(for snapshot: ProviderBalanceSnapshot) -> String? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        if let resetsAt = snapshot.resetsAt {
            return "Resets \(formatter.string(from: resetsAt))"
        }
        if let expiresAt = snapshot.expiresAt {
            return "Expires \(formatter.string(from: expiresAt))"
        }
        return nil
    }

    private static func allowanceSummary(
        remaining: Double,
        total: Double?,
        unit: ProviderBalanceUnit,
        label: String
    ) -> String {
        guard let total else {
            return "\(number(remaining)) \(unit.displayName) \(label) (limit unknown)"
        }
        return "\(number(remaining)) of \(number(total)) \(unit.displayName) \(label)"
    }

    /// Formats money without `NumberFormatter`'s locale-dependent currency
    /// symbols, so the string is the same everywhere and in tests.
    private static func formatMoney(_ money: ProviderBalanceMoney) -> String {
        let rounded = NSDecimalNumber(decimal: money.amount)
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 2,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            ))
        let digits = String(format: "%.2f", rounded.doubleValue)
        switch money.currencyCode {
        case "USD": return "$\(digits)"
        case "GBP": return "£\(digits)"
        case "EUR": return "€\(digits)"
        default: return "\(digits) \(money.currencyCode)"
        }
    }

    private static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
