import Foundation

/// How finely a provider lets one key be limited.
public enum APIKeyScopeSupport: Equatable, Sendable {
    /// The key can be limited to named permissions, roles or restrictions.
    case granular
    /// The provider documents no per-key permissions; the text says what does
    /// limit access instead.
    case none(String)
}

/// Whether the provider lets a key be created with an end date.
public enum APIKeyExpirySetting: Equatable, Sendable {
    /// Offered when the key is created, under the provider's own label.
    case configurable(String)
    /// The provider states that keys do not expire.
    case notOffered
    /// The provider's documentation describes no expiry for this key type.
    case notDocumented
}

/// What the provider itself says about expiry and rotation. A recommendation
/// is quoted or closely paraphrased; nil means none is published.
public struct APIKeyExpiryGuidance: Equatable, Sendable {
    public let setting: APIKeyExpirySetting
    public let providerRecommendation: String?

    public init(_ setting: APIKeyExpirySetting, providerRecommendation: String? = nil) {
        self.setting = setting
        self.providerRecommendation = providerRecommendation
    }
}

/// The permissions one use of a key needs, and the requests behind them.
public struct APIKeyPermissionRequirement: Equatable, Sendable {
    /// The feature that needs this. Nil means the key check every save runs.
    public let use: APIKeyUses?
    public let permissions: [String]
    public let endpoints: [String]
    public let note: String?
    /// Optional extras, such as a balance line, never join the minimum.
    public let isOptional: Bool

    public init(
        _ use: APIKeyUses?, permissions: [String], endpoints: [String], note: String? = nil, isOptional: Bool = false
    ) {
        self.use = use
        self.permissions = permissions
        self.endpoints = endpoints
        self.note = note
        self.isOptional = isOptional
    }

    var title: String {
        if isOptional { return "Optional" }
        guard let use else { return "Key check" }
        return use.summary
    }
}

/// Least-privilege key-creation guidance for one provider credential.
///
/// Every statement comes from the provider's own documentation, linked in
/// `sources`, as read on `APIKeyGuidance.lastVerified`. None of it has been
/// exercised with restricted test keys, and the text says so rather than
/// calling a combination verified.
public struct APIKeyProviderGuide: Equatable, Sendable {
    public let providerName: String
    public let identifiers: Set<String>
    /// The official page where the key is created. It never carries a scope
    /// preset: no provider here documents one.
    public let creationURL: URL
    public let steps: [String]
    public let scopes: APIKeyScopeSupport
    public let requirements: [APIKeyPermissionRequirement]
    public let expiry: APIKeyExpiryGuidance
    public let notes: [String]
    public let sources: [URL]

    /// The applicable requirements for `uses`: the key check always applies,
    /// and optional extras are listed after the minimum.
    public func requirements(for uses: APIKeyUses) -> [APIKeyPermissionRequirement] {
        let applicable = requirements.filter { requirement in
            guard let use = requirement.use else { return true }
            return !use.isDisjoint(with: uses)
        }
        return applicable.filter { !$0.isOptional } + applicable.filter(\.isOptional)
    }

    /// The union of permissions the selected uses need, in catalogue order.
    /// A key shared by several features needs all of them, and nothing more.
    public func minimumPermissions(for uses: APIKeyUses) -> [String] {
        var seen = Set<String>()
        return requirements(for: uses).filter { !$0.isOptional }
            .flatMap(\.permissions)
            .filter { seen.insert($0).inserted }
    }

    /// The full guide as plain lines, for a disclosure or an alert.
    public func lines(for uses: APIKeyUses) -> [String] {
        var lines = ["Create the key: " + steps.joined(separator: " → ") + "."]
        switch scopes {
        case .granular:
            let minimum = minimumPermissions(for: uses)
            if !minimum.isEmpty {
                lines.append("Minimum permissions for \(uses.summary): " + minimum.joined(separator: "; ") + ".")
            }
        case .none(let limitation):
            lines.append("Permissions: \(providerName) keys have no per-feature scopes. \(limitation)")
        }
        for requirement in requirements(for: uses) {
            var line = "\(requirement.title): "
            if case .granular = scopes, !requirement.permissions.isEmpty {
                line += requirement.permissions.joined(separator: "; ") + " for "
            }
            line += requirement.endpoints.joined(separator: ", ") + "."
            if let note = requirement.note { line += " " + note }
            lines.append(line)
        }
        lines += notes
        lines.append(
            "Preselection: \(providerName) does not document a link that opens key creation with permissions "
                + "chosen, so choose them by hand."
        )
        lines.append(expiryLine)
        lines.append(APIKeyGuidance.appAdvice)
        lines.append(APIKeyGuidance.replacementAdvice)
        lines.append(APIKeyGuidance.verificationNote)
        return lines
    }

    /// One short paragraph for the Windows and Linux API Keys rows, which
    /// show a single hint line beside the entry format.
    public func compactHint(for uses: APIKeyUses) -> String {
        let permissions: String
        switch scopes {
        case .granular:
            permissions = "Minimum permissions: " + minimumPermissions(for: uses).joined(separator: "; ") + "."
        case .none:
            permissions = "No per-feature scopes."
        }
        let expiry: String
        switch self.expiry.setting {
        case .configurable(let label): expiry = "Set \(label) when creating it."
        case .notOffered: expiry = "Keys do not expire; replace it if it may have leaked."
        case .notDocumented: expiry = "No expiry setting is documented; replace it if it may have leaked."
        }
        return "\(permissions) \(expiry)"
    }

    var expiryLine: String {
        var line: String
        switch expiry.setting {
        case .configurable(let label):
            line = "Expiry: \(providerName) lets you set \(label) when creating the key."
        case .notOffered:
            line = "Expiry: \(providerName) keys do not expire; they work until you delete or reset them."
        case .notDocumented:
            line = "Expiry: \(providerName) documents no expiry setting for these keys."
        }
        if let recommendation = expiry.providerRecommendation {
            line += " \(providerName) advises: \(recommendation)"
        } else {
            line += " \(providerName) publishes no recommended key lifetime."
        }
        return line
    }
}

/// The canonical guide list. Platforms show the guide for the credentials
/// they expose; adding a provider credential without a guide fails a test.
public enum APIKeyGuidance {
    /// When every guide below was last checked against its sources.
    public static let lastVerified = "2026-11-03"

    static let verificationNote = "Checked against \(lastVerified) provider documentation. Speak has not tested "
        + "every permission combination with restricted keys; if a request is refused, compare the permission "
        + "names with the provider's sources."

    static let appAdvice = "Speak's advice, not the provider's: use a key only for Speak, give it the shortest "
        + "expiry you will reliably renew, review it when you review billing, and replace it at once if it may "
        + "have leaked."

    static let replacementAdvice = "Replacing a key: create the new key first, paste it here and save. Speak keeps "
        + "it under the same name, so your models, prompts and voices stay selected. Then delete the old key "
        + "at the provider."

    public static func guide(for identifier: String) -> APIKeyProviderGuide? {
        guides.first { $0.identifiers.contains(identifier) }
    }

    /// The creation page for a credential, or nil when no guide exists.
    public static func creationURL(for identifier: String) -> URL? {
        guide(for: identifier)?.creationURL
    }

    /// The one sentence a missing-key prompt adds about permissions.
    public static func promptSummary(for identifier: String, uses: APIKeyUses) -> String? {
        guard let guide = guide(for: identifier) else { return nil }
        switch guide.scopes {
        case .granular:
            let minimum = guide.minimumPermissions(for: uses)
            guard !minimum.isEmpty else { return nil }
            return "Create the key with only: " + minimum.joined(separator: "; ") + "."
        case .none:
            return "\(guide.providerName) keys have no per-feature scopes; create one used only for Speak."
        }
    }

    static func url(_ string: String) -> URL {
        // Literals only; the tests check every one is an HTTPS URL.
        URL(string: string) ?? OpenRouterService.apiKeysURL
    }
}
