import Foundation

// MARK: - Matchers

/// A rule binding a dictation profile to a target context.
///
/// Today only `bundleID` matchers are evaluated (macOS frontmost-app matching).
/// `urlPattern` is reserved so browser URL matching (Safari/Chrome via AX) can be
/// added later without a storage or sync format change; unknown kinds written by
/// newer clients are dropped on decode instead of failing the whole profile list.
public struct DictationProfileMatcher: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Matches the frontmost application's bundle identifier (case-insensitive).
        case bundleID
        /// Reserved: matches the frontmost browser tab's URL. Not evaluated yet.
        case urlPattern
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind = .bundleID, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func bundleID(_ identifier: String) -> DictationProfileMatcher {
        DictationProfileMatcher(kind: .bundleID, value: identifier)
    }
}

// MARK: - Profile

/// A per-app dictation configuration ("Power Mode" profile).
///
/// Every override is optional; `nil` means "keep the user's normal setting".
/// A resolved profile is applied for the duration of a single dictation session
/// and never mutates the persisted defaults.
public struct DictationProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var matchers: [DictationProfileMatcher]

    /// Transcription model override (catalog identifier, e.g. `deepgram/nova-3-streaming`
    /// or `openai/whisper-1`). The transcription mode is derived from the identifier.
    public var transcriptionModelID: String?

    /// Whether LLM polish (post-processing) runs for this profile.
    public var polishEnabled: Bool?
    /// Polish model override (catalog identifier).
    public var polishModelID: String?
    /// Custom polish system prompt replacing the built-in cleanup prompt.
    public var polishPrompt: String?
    /// Output language for the polished transcript (e.g. `British English`).
    public var polishOutputLanguage: String?
    /// Formatting: include personal-lexicon normalisation directives in the prompt.
    public var polishIncludeLexiconDirectives: Bool?
    /// Formatting: include detected context tags in the prompt.
    public var polishIncludeContextTags: Bool?

    /// Spoken-language override (`TranscriptionLanguageCatalog` identifier, e.g. `en_GB`).
    public var languageIdentifier: String?

    public init(
        id: UUID = UUID(),
        name: String,
        matchers: [DictationProfileMatcher] = [],
        transcriptionModelID: String? = nil,
        polishEnabled: Bool? = nil,
        polishModelID: String? = nil,
        polishPrompt: String? = nil,
        polishOutputLanguage: String? = nil,
        polishIncludeLexiconDirectives: Bool? = nil,
        polishIncludeContextTags: Bool? = nil,
        languageIdentifier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.matchers = matchers
        self.transcriptionModelID = transcriptionModelID
        self.polishEnabled = polishEnabled
        self.polishModelID = polishModelID
        self.polishPrompt = polishPrompt
        self.polishOutputLanguage = polishOutputLanguage
        self.polishIncludeLexiconDirectives = polishIncludeLexiconDirectives
        self.polishIncludeContextTags = polishIncludeContextTags
        self.languageIdentifier = languageIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case matchers
        case transcriptionModelID
        case polishEnabled
        case polishModelID
        case polishPrompt
        case polishOutputLanguage
        case polishIncludeLexiconDirectives
        case polishIncludeContextTags
        case languageIdentifier
    }

    /// Wrapper making individual matcher decode failures (e.g. a kind added by a
    /// newer client) non-fatal for the containing profile.
    private struct LossyMatcher: Decodable {
        let matcher: DictationProfileMatcher?

        init(from decoder: Decoder) throws {
            matcher = try? DictationProfileMatcher(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let lossyMatchers = try container.decodeIfPresent([LossyMatcher].self, forKey: .matchers) ?? []
        matchers = lossyMatchers.compactMap(\.matcher)
        transcriptionModelID = try container.decodeIfPresent(String.self, forKey: .transcriptionModelID)
        polishEnabled = try container.decodeIfPresent(Bool.self, forKey: .polishEnabled)
        polishModelID = try container.decodeIfPresent(String.self, forKey: .polishModelID)
        polishPrompt = try container.decodeIfPresent(String.self, forKey: .polishPrompt)
        polishOutputLanguage = try container.decodeIfPresent(String.self, forKey: .polishOutputLanguage)
        polishIncludeLexiconDirectives = try container.decodeIfPresent(
            Bool.self, forKey: .polishIncludeLexiconDirectives
        )
        polishIncludeContextTags = try container.decodeIfPresent(Bool.self, forKey: .polishIncludeContextTags)
        languageIdentifier = try container.decodeIfPresent(String.self, forKey: .languageIdentifier)
    }
}

// MARK: - List serialisation

public extension DictationProfile {
    /// Canonical JSON encoding used by the local store and cross-device transfer.
    static func encodeList(_ profiles: [DictationProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(profiles)
    }

    static func decodeList(_ data: Data) throws -> [DictationProfile] {
        try JSONDecoder().decode([DictationProfile].self, from: data)
    }
}

// MARK: - Resolver

/// Resolves which profile applies to a dictation session.
///
/// Precedence: the first profile in user order with an explicit bundle-ID match
/// wins. When nothing matches (or no bundle ID is known) the resolver returns
/// `nil`, which means "use the app's normal settings" — the implicit default
/// profile that preserves today's behaviour.
public struct ProfileResolver: Sendable {
    public var profiles: [DictationProfile]

    public init(profiles: [DictationProfile]) {
        self.profiles = profiles
    }

    public func profile(forBundleID bundleID: String?) -> DictationProfile? {
        guard let target = Self.normalized(bundleID) else { return nil }
        return profiles.first { profile in
            profile.matchers.contains { matcher in
                matcher.kind == .bundleID && Self.normalized(matcher.value) == target
            }
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
