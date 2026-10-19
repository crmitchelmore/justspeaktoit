import Foundation

/// The features one stored provider credential serves.
public struct APIKeyUses: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let transcription = APIKeyUses(rawValue: 1 << 0)
    public static let postProcessing = APIKeyUses(rawValue: 1 << 1)
    public static let voiceOutput = APIKeyUses(rawValue: 1 << 2)

    public var summary: String {
        var parts: [String] = []
        if contains(.transcription) { parts.append("Transcription") }
        if contains(.postProcessing) { parts.append("Post-processing") }
        if contains(.voiceOutput) { parts.append("Voice Output") }
        return parts.joined(separator: ", ")
    }
}

/// How a stored value is shaped. Composite values are never partly displayed.
public enum APIKeyFormat: Equatable, Sendable {
    case plain
    case azureKeyAndRegion
    case alibabaConfiguration

    public init(identifier: String) {
        switch identifier {
        case AzureSpeechConfiguration.credentialIdentifier: self = .azureKeyAndRegion
        case AlibabaSpeechConfiguration.credentialIdentifier: self = .alibabaConfiguration
        default: self = .plain
        }
    }

    public var entryHint: String {
        switch self {
        case .plain:
            return "Paste the provider's API key."
        case .azureKeyAndRegion:
            return "Enter key:region, for example abc123:westeurope. With a local proxy endpoint, "
                + "enter local-proxy/ followed by its token."
        case .alibabaConfiguration:
            return "Enter the Alibaba Model Studio key, region and workspace in the saved format."
        }
    }
}

/// One credential a platform can use, keyed by its secure-storage identifier.
public struct APIKeyCatalogEntry: Equatable, Sendable, Identifiable {
    public let identifier: String
    public let providerName: String
    public internal(set) var uses: APIKeyUses
    public internal(set) var keyPageURL: URL?

    public var id: String { identifier }
    public var format: APIKeyFormat { APIKeyFormat(identifier: identifier) }

    /// OpenAI keeps Voice Output apart from transcription, so its label says so.
    public var label: String {
        identifier == OpenAITTSCatalog.credentialIdentifier ? "OpenAI Voice Output" : providerName
    }
}

/// A credential requirement contributed by one model or voice route.
public struct APIKeyCatalogSource: Equatable, Sendable {
    public let identifier: String
    public let providerName: String
    public let use: APIKeyUses
    public let keyPageURL: URL?

    public init(identifier: String, providerName: String, use: APIKeyUses, keyPageURL: URL? = nil) {
        self.identifier = identifier
        self.providerName = providerName
        self.use = use
        self.keyPageURL = keyPageURL
    }

    /// The resolver's requirement for a model, or nil when it needs no key.
    public static func model(
        _ modelIdentifier: String, purpose: ModelCredentialPurpose, keyPageURL: URL? = nil
    ) -> APIKeyCatalogSource? {
        guard case .apiKey(let identifier, let providerName) = ModelCredentialResolver.requirement(
            for: modelIdentifier, purpose: purpose
        ) else { return nil }
        let use: APIKeyUses
        switch purpose {
        case .liveTranscription, .batchTranscription: use = .transcription
        case .postProcessing: use = .postProcessing
        case .voiceOutput: use = .voiceOutput
        }
        return APIKeyCatalogSource(
            identifier: identifier, providerName: providerName, use: use, keyPageURL: keyPageURL
        )
    }
}

/// The API Keys page projection of the canonical model and voice catalogues.
/// Platforms pass only routes they implement; this type never adds a provider.
public enum APIKeyCatalog {
    public static let maximumKeyBytes = 8_192
    static let minimumMaskedLength = 16

    /// One entry per identifier, merging uses. OpenRouter leads because it backs
    /// post-processing and most recorded-audio models; the rest sort by label.
    public static func entries(_ sources: [APIKeyCatalogSource]) -> [APIKeyCatalogEntry] {
        var order: [String] = []
        var merged: [String: APIKeyCatalogEntry] = [:]
        for source in sources where !source.identifier.isEmpty {
            if var entry = merged[source.identifier] {
                entry.uses.formUnion(source.use)
                if entry.keyPageURL == nil { entry.keyPageURL = source.keyPageURL }
                merged[source.identifier] = entry
            } else {
                order.append(source.identifier)
                merged[source.identifier] = APIKeyCatalogEntry(
                    identifier: source.identifier,
                    providerName: providerName(for: source.identifier, fallback: source.providerName),
                    uses: source.use,
                    keyPageURL: source.keyPageURL ?? keyPageURL(for: source.identifier)
                )
            }
        }
        return order.compactMap { merged[$0] }.sorted { lhs, rhs in
            let lhsFirst = lhs.identifier == openRouterIdentifier
            let rhsFirst = rhs.identifier == openRouterIdentifier
            if lhsFirst != rhsFirst { return lhsFirst }
            let comparison = lhs.label.caseInsensitiveCompare(rhs.label)
            return comparison == .orderedSame
                ? lhs.identifier < rhs.identifier : comparison == .orderedAscending
        }
    }

    static let openRouterIdentifier = "openrouter.apiKey"

    private static func providerName(for identifier: String, fallback: String) -> String {
        // The resolver names Azure "Azure" for voices and "Azure Speech" for
        // transcription; one stored credential gets one stable name.
        identifier == AzureSpeechConfiguration.credentialIdentifier ? "Azure Speech" : fallback
    }

    /// Where the provider issues keys, derived from the same catalogue metadata
    /// the per-feature editors use. Only HTTPS pages are returned.
    public static func keyPageURL(for identifier: String) -> URL? {
        let url: URL?
        switch identifier {
        case openRouterIdentifier:
            url = OpenRouterService.apiKeysURL
        case "openai.apiKey", OpenAITTSCatalog.credentialIdentifier:
            url = URL(string: "https://platform.openai.com/api-keys")
        case GroqTTSCatalog.credentialIdentifier:
            url = URL(string: GroqBatchClient(keywords: []).metadata.website)
        default:
            if let provider = FileSpeechProvider.allCases.first(where: { "\($0.rawValue).apiKey" == identifier }) {
                url = URL(string: provider.metadata.website)
            } else {
                url = LiveTranscriptionProviderID.allCases
                    .first { $0.apiKeyIdentifier == identifier }?.apiKeyURL
            }
        }
        guard let url, url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// A non-reversible hint for a saved value: never more than the last four
    /// characters of a long plain key, and nothing of composite values beyond
    /// their non-secret parts.
    public static func maskedSuffix(_ key: String, identifier: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch APIKeyFormat(identifier: identifier) {
        case .alibabaConfiguration:
            return nil
        case .azureKeyAndRegion:
            if trimmed.hasPrefix(AzureSpeechConfiguration.proxyCredentialPrefix) { return "local proxy token" }
            guard let configuration = try? AzureSpeechConfiguration(credentials: trimmed),
                  let suffix = plainSuffix(configuration.apiKey) else { return nil }
            return "\(suffix), region \(configuration.region)"
        case .plain:
            return plainSuffix(trimmed)
        }
    }

    private static func plainSuffix(_ key: String) -> String? {
        guard key.count >= minimumMaskedLength else { return nil }
        return "••••" + String(key.suffix(4))
    }

    /// Trims the typed value and rejects what no provider credential can be.
    public static func sanitizedKey(_ key: String) throws -> String {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw APIKeyEntryError.empty }
        guard cleaned.utf8.count <= maximumKeyBytes,
              cleaned.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw APIKeyEntryError.invalid
        }
        return cleaned
    }
}

public enum APIKeyEntryError: LocalizedError, Equatable, Sendable {
    case empty, invalid, unknownProvider

    public var errorDescription: String? {
        switch self {
        case .empty: return "Paste a key to save it. The saved key is unchanged."
        case .invalid: return "The key contains control characters or exceeds 8,192 UTF-8 bytes."
        case .unknownProvider: return "This provider is no longer available on this device."
        }
    }
}

/// The identifiers that currently hold a stored secret, kept sorted and unique
/// exactly like the Mac's `trackedKeyIdentifiers` preference: storing a
/// non-empty value registers its identifier, storing an empty value or removing
/// the key forgets it, and loading reconciles with the secure store.
public struct TrackedAPIKeyIdentifiers: Codable, Equatable, Sendable {
    public private(set) var identifiers: [String]

    public init(_ identifiers: [String] = []) {
        self.identifiers = Self.canonical(identifiers)
    }

    public func contains(_ identifier: String) -> Bool { identifiers.contains(identifier) }

    @discardableResult
    public mutating func register(_ identifier: String) -> Bool { reconcile(identifiers + [identifier]) }

    @discardableResult
    public mutating func remove(_ identifier: String) -> Bool {
        reconcile(identifiers.filter { $0 != identifier })
    }

    /// Mirrors a secure-storage write of `value` under `identifier`.
    @discardableResult
    public mutating func record(_ identifier: String, storedValue value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? remove(identifier) : register(identifier)
    }

    /// Returns whether the canonical list changed, so callers persist only then.
    @discardableResult
    public mutating func reconcile(_ stored: [String]) -> Bool {
        let canonical = Self.canonical(stored)
        guard canonical != identifiers else { return false }
        identifiers = canonical
        return true
    }

    private static func canonical(_ identifiers: [String]) -> [String] {
        Array(Set(identifiers.filter { !$0.isEmpty })).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case identifiers = "trackedKeyIdentifiers"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decodeIfPresent([String].self, forKey: .identifiers) ?? [])
    }
}
