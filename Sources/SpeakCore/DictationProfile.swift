import Foundation

// MARK: - Matchers

/// A rule binding a dictation profile to a target context.
///
/// `bundleID` matchers are evaluated on macOS (frontmost-app matching) and
/// `windowsExecutablePath` matchers on Windows (the captured application's
/// full executable path). Each platform evaluates only its own kind and keeps
/// the others untouched when it edits a profile, so one profile list can carry
/// both. `urlPattern` is reserved so browser URL matching (Safari/Chrome via AX)
/// can be added later without a storage or sync format change; unknown kinds
/// written by newer clients are dropped on decode instead of failing the whole
/// profile list.
public struct DictationProfileMatcher: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Matches the frontmost application's bundle identifier (case-insensitive).
        case bundleID
        /// Reserved: matches the frontmost browser tab's URL. Not evaluated yet.
        case urlPattern
        /// Matches the full executable path of the Windows process that owned the
        /// captured text target, compared as an exact path after
        /// `normalizedWindowsExecutablePath` (case-insensitive, `\` separators,
        /// no `\\?\` prefix). A bare file name or a bundle identifier never
        /// matches; nothing is inferred from a process name.
        case windowsExecutablePath
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

    public static func windowsExecutablePath(_ path: String) -> DictationProfileMatcher {
        DictationProfileMatcher(kind: .windowsExecutablePath, value: path)
    }
}

// MARK: - Windows executable paths

public extension DictationProfileMatcher {
    /// The comparison form of a Windows executable path: surrounding whitespace
    /// trimmed, `/` folded to `\`, the `\\?\` and `\\?\UNC\` prefixes removed
    /// and everything lower-cased, because Windows compares paths without regard
    /// to case. `nil` for a blank value, which never matches anything.
    static func normalizedWindowsExecutablePath(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        var path = trimmed.replacingOccurrences(of: "/", with: "\\").lowercased()
        if path.hasPrefix("\\\\?\\unc\\") {
            path = "\\\\" + path.dropFirst("\\\\?\\unc\\".count)
        } else if path.hasPrefix("\\\\?\\") {
            path = String(path.dropFirst("\\\\?\\".count))
        }
        return path.isEmpty ? nil : path
    }

    /// Whether `path` names a specific file by its complete Windows path: a
    /// drive-letter path such as `C:\Apps\App.exe` or a UNC path with a server,
    /// share and file name. Relative paths and bare names are rejected so a
    /// matcher can only ever describe the exact application it was chosen for.
    static func isFullWindowsExecutablePath(_ path: String) -> Bool {
        guard let normalized = normalizedWindowsExecutablePath(path), !normalized.hasSuffix("\\") else {
            return false
        }
        let scalars = Array(normalized.unicodeScalars)
        guard !scalars.contains(where: { $0.value < 32 || "<>\"|?*".unicodeScalars.contains($0) }) else {
            return false
        }
        let components: [Substring]
        if scalars.count >= 4, ("a"..."z").contains(scalars[0]), scalars[1] == ":", scalars[2] == "\\" {
            components = normalized.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
        } else {
            guard normalized.hasPrefix("\\\\") else { return false }
            components = normalized.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false)
            guard components.count >= 3 else { return false }
        }
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":")
                && !$0.hasSuffix(".") && !$0.hasSuffix(" ")
        }
    }
}

// MARK: - Profile

/// How a profile's transcription model override is routed. Stored explicitly
/// so a custom identifier the catalogue does not list is applied the way the
/// editor showed it, never re-classified by guesswork (issue #690).
public enum DictationProfileTranscriptionRouting: String, Codable, Equatable, Sendable, CaseIterable {
    /// A cloud streaming model used while recording.
    case remoteStreaming
    /// A cloud batch model the finished recording is sent to.
    case remoteBatch
    /// A downloaded local model run after recording.
    case localBatch
}

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
    /// or `openai/whisper-1`). Routed by `transcriptionRouting` when set; profiles saved
    /// before routing metadata existed derive it from the identifier.
    public var transcriptionModelID: String?
    /// How `transcriptionModelID` is applied. `nil` for profiles saved by older builds.
    public var transcriptionRouting: DictationProfileTranscriptionRouting?

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
        languageIdentifier: String? = nil,
        transcriptionRouting: DictationProfileTranscriptionRouting? = nil
    ) {
        self.id = id
        self.name = name
        self.matchers = matchers
        self.transcriptionModelID = transcriptionModelID
        self.transcriptionRouting = transcriptionRouting
        self.polishEnabled = polishEnabled
        self.polishModelID = polishModelID
        self.polishPrompt = polishPrompt
        self.polishOutputLanguage = polishOutputLanguage
        self.polishIncludeLexiconDirectives = polishIncludeLexiconDirectives
        self.polishIncludeContextTags = polishIncludeContextTags
        self.languageIdentifier = languageIdentifier
    }

    /// The pre-#690 initializer, kept for source and API compatibility (#791).
    /// A profile created this way carries no explicit routing, so the applier
    /// derives it from the model identifier exactly as it does for profiles
    /// saved before routing metadata existed. Calls without `transcriptionRouting:`
    /// resolve here (fewer parameters win); calls with it use the designated
    /// initializer.
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
        self.init(
            id: id,
            name: name,
            matchers: matchers,
            transcriptionModelID: transcriptionModelID,
            polishEnabled: polishEnabled,
            polishModelID: polishModelID,
            polishPrompt: polishPrompt,
            polishOutputLanguage: polishOutputLanguage,
            polishIncludeLexiconDirectives: polishIncludeLexiconDirectives,
            polishIncludeContextTags: polishIncludeContextTags,
            languageIdentifier: languageIdentifier,
            transcriptionRouting: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case matchers
        case transcriptionModelID
        case transcriptionRouting
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
        // A routing written by a newer build is dropped rather than failing the profile;
        // the legacy derivation then applies.
        transcriptionRouting = try? container.decodeIfPresent(
            DictationProfileTranscriptionRouting.self, forKey: .transcriptionRouting
        )
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

// MARK: - Routing

public extension DictationProfile {
    /// Routing for a profile saved before explicit metadata existed: catalogue live
    /// models stream, `local/` identifiers run locally, everything else is remote batch.
    static func derivedTranscriptionRouting(for modelID: String) -> DictationProfileTranscriptionRouting {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if ModelCatalog.liveTranscription.contains(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .remoteStreaming
        }
        if trimmed.lowercased().hasPrefix("local/") {
            return .localBatch
        }
        return .remoteBatch
    }

    /// The transcription override as a (model, routing) pair, or `nil` when the profile
    /// keeps the user's own transcription settings.
    var resolvedTranscriptionOverride: (modelID: String, routing: DictationProfileTranscriptionRouting)? {
        guard let modelID = transcriptionModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else {
            return nil
        }
        return (modelID, transcriptionRouting ?? Self.derivedTranscriptionRouting(for: modelID))
    }
}

// MARK: - Platform-owned matchers

public extension DictationProfile {
    /// The Windows executable paths this profile matches, in stored order.
    var windowsExecutablePaths: [String] {
        matchers.filter { $0.kind == .windowsExecutablePath }.map(\.value)
    }

    /// A copy whose Windows matchers are replaced by `paths`. Every other
    /// matcher — macOS bundle identifiers and reserved URL patterns — keeps its
    /// value and relative order, so a Windows edit never loses what the Mac
    /// editor stored (and vice versa once it adopts the same rule).
    func replacingWindowsExecutablePaths(_ paths: [String]) -> DictationProfile {
        var copy = self
        copy.matchers = matchers.filter { $0.kind != .windowsExecutablePath }
            + paths.map(DictationProfileMatcher.windowsExecutablePath)
        return copy
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
/// Precedence: the first profile in user order with an explicit match for the
/// platform's own matcher kind wins. When nothing matches (or no application
/// identity is known) the resolver returns `nil`, which means "use the app's
/// normal settings" — the implicit default profile that preserves today's
/// behaviour. The Windows lookup ignores bundle-ID matchers and the macOS
/// lookup ignores executable paths; neither derives one identity from the other.
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

    /// The first profile whose Windows matcher names exactly the captured
    /// application's full executable path (see
    /// `DictationProfileMatcher.normalizedWindowsExecutablePath`).
    public func profile(forWindowsExecutablePath path: String?) -> DictationProfile? {
        guard let target = DictationProfileMatcher.normalizedWindowsExecutablePath(path),
              DictationProfileMatcher.isFullWindowsExecutablePath(target) else { return nil }
        return profiles.first { profile in
            profile.matchers.contains { matcher in
                matcher.kind == .windowsExecutablePath
                    && DictationProfileMatcher.normalizedWindowsExecutablePath(matcher.value) == target
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
