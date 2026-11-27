import Foundation

/// Supported desktop-only local or authenticated voice studio backends.
public enum VoiceStudioKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case voicebox = "studio/voicebox"
    case voiceStudio = "studio/voicestudio"
    case gptSoVITS = "studio/gpt-sovits"

    public var id: String { rawValue }

    /// Short canonical identifier used in credential storage and voice IDs.
    public var slug: String {
        switch self {
        case .voicebox: "voicebox"
        case .voiceStudio: "voicestudio"
        case .gptSoVITS: "gpt-sovits"
        }
    }

    /// Human-readable studio product name shown in settings, pickers, and errors.
    public var displayName: String {
        switch self {
        case .voicebox: "Voicebox"
        case .voiceStudio: "VoiceStudio"
        case .gptSoVITS: "GPT-SoVITS"
        }
    }

    /// Loopback default endpoint when no custom URL has been entered.
    public var defaultBaseURLString: String {
        switch self {
        case .voicebox: "http://127.0.0.1:17493"
        case .voiceStudio: "http://localhost:8000"
        case .gptSoVITS: "http://127.0.0.1:9880"
        }
    }

    public var defaultBaseURL: URL {
        // Static RFC-valid loopback literals always construct a valid URL.
        URL(string: defaultBaseURLString)!
    }

    /// Stable non-cloud credential slot key in the platform secure store / Keychain.
    public var apiKeyCredentialIdentifier: String {
        "tts.studio.\(slug).api_key"
    }

    /// Whether the studio exposes a runtime list of voices or profiles via HTTP.
    public var supportsVoiceDiscovery: Bool {
        switch self {
        case .voicebox, .voiceStudio: true
        case .gptSoVITS: false
        }
    }

    /// Whether the studio supports importing/creating a cloned voice profile via HTTP.
    public var supportsProfilePush: Bool {
        self == .voicebox
    }

    /// Whether synthesis requires a user-supplied reference audio clip and prompt text.
    public var requiresReferenceAudio: Bool {
        self == .gptSoVITS
    }

    /// Summary shown in Settings describing how voices are retrieved or configured.
    public var voiceListEndpointSummary: String {
        switch self {
        case .voicebox: "GET /profiles"
        case .voiceStudio: "GET /v1/audio/voices"
        case .gptSoVITS: "Reference clip & prompt"
        }
    }

    /// Summary shown in Settings describing the speech generation endpoint.
    public var speechEndpointSummary: String {
        switch self {
        case .voicebox: "POST /generate"
        case .voiceStudio: "POST /v1/audio/speech"
        case .gptSoVITS: "POST /tts"
        }
    }

    /// Parses either a canonical `studio/...` identifier or short slug case-insensitively.
    public static func from(rawOrSlug value: String) -> Self? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = Self(rawValue: normalized) {
            return exact
        }
        return allCases.first { $0.slug == normalized }
    }
}

/// Shared preference keys and language presets for local voice studio settings.
public enum VoiceStudioPreference {
    public static let enabledKey = "voiceStudioEnabled"
    public static let kindKey = "voiceStudioKind"
    public static let baseURLKey = "voiceStudioBaseURL"
    public static let gptSoVITSReferenceAudioPathKey = "voiceStudioGPTSoVITSReferenceAudioPath"
    public static let gptSoVITSReferencePromptTextKey = "voiceStudioGPTSoVITSReferencePromptText"
    public static let gptSoVITSReferencePromptLanguageKey = "voiceStudioGPTSoVITSPromptLanguage"
    public static let gptSoVITSTextLanguageKey = "voiceStudioGPTSoVITSTextLanguage"

    public static let defaultGPTSoVITSLanguage = "en"

    public static let gptSoVITSSupportedLanguages: [(code: String, label: String)] = [
        ("en", "English (en)"),
        ("zh", "Chinese (zh)"),
        ("ja", "Japanese (ja)"),
        ("ko", "Korean (ko)"),
        ("yue", "Cantonese (yue)"),
        ("auto", "Auto-detect (auto)")
    ]

    public static let allSettingKeys: [String] = [
        enabledKey,
        kindKey,
        baseURLKey,
        gptSoVITSReferenceAudioPathKey,
        gptSoVITSReferencePromptTextKey,
        gptSoVITSReferencePromptLanguageKey,
        gptSoVITSTextLanguageKey
    ]
}

/// Canonical studio voice exposed through `DesktopSpeechVoice.studio(...)` and Read Aloud pickers.
public struct VoiceStudioVoice: Equatable, Hashable, Identifiable, Codable, Sendable {
    public static let gptSoVITSReferenceVoiceID = "reference"

    public let studioKind: VoiceStudioKind
    public let remoteVoiceID: String
    public let name: String
    public let language: String?
    public let summary: String?
    public let sampleCount: Int?

    public init(
        studioKind: VoiceStudioKind,
        remoteVoiceID: String,
        name: String,
        language: String? = nil,
        summary: String? = nil,
        sampleCount: Int? = nil
    ) {
        self.studioKind = studioKind
        self.remoteVoiceID = remoteVoiceID
        self.name = name
        self.language = language
        self.summary = summary
        self.sampleCount = sampleCount
    }

    /// Stable desktop voice identifier prefixed with the canonical studio identifier.
    public var id: String {
        "\(studioKind.rawValue)/\(remoteVoiceID)"
    }

    public var label: String {
        if let language, !language.isEmpty {
            return "\(name) — \(studioKind.displayName) (\(language))"
        }
        return "\(name) — \(studioKind.displayName)"
    }

    public var modelIdentifier: String { studioKind.rawValue }

    public var capabilities: VoiceSynthesisCapabilities { .naturalSpeech }

    /// Extracts the underlying remote voice identifier when given a canonical studio voice ID.
    public static func remoteVoiceID(fromCanonicalID identifier: String, kind: VoiceStudioKind) -> String? {
        let prefix = "\(kind.rawValue)/"
        guard identifier.hasPrefix(prefix) else { return nil }
        let suffix = String(identifier.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    /// Parses which studio kind owns a canonical `studio/...` voice ID or model ID.
    public static func kind(forCanonicalID identifier: String) -> VoiceStudioKind? {
        VoiceStudioKind.allCases.first { kind in
            identifier == kind.rawValue || identifier.hasPrefix("\(kind.rawValue)/")
        }
    }

    /// Synthetic Read Aloud voice entry used when GPT-SoVITS is configured.
    public static func gptSoVITSDefaultVoice(language: String? = nil) -> Self {
        let normalizedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            studioKind: .gptSoVITS,
            remoteVoiceID: gptSoVITSReferenceVoiceID,
            name: "GPT-SoVITS Reference Voice",
            language: normalizedLanguage?.isEmpty == true ? nil : normalizedLanguage,
            summary: "Uses the configured reference clip and prompt text"
        )
    }
}

/// Non-secret local voice studio settings captured on desktop platforms.
/// API keys are never embedded here and always come from platform secure storage.
public struct VoiceStudioConfiguration: Equatable, Hashable, Codable, Sendable {
    public var enabled: Bool
    public var kind: VoiceStudioKind
    public var baseURLString: String
    public var gptSoVITSReferenceAudioPath: String
    public var gptSoVITSReferencePromptText: String
    public var gptSoVITSReferencePromptLanguage: String
    public var gptSoVITSTextLanguage: String

    public init(
        enabled: Bool = false,
        kind: VoiceStudioKind = .voicebox,
        baseURLString: String = "",
        gptSoVITSReferenceAudioPath: String = "",
        gptSoVITSReferencePromptText: String = "",
        gptSoVITSReferencePromptLanguage: String = VoiceStudioPreference.defaultGPTSoVITSLanguage,
        gptSoVITSTextLanguage: String = VoiceStudioPreference.defaultGPTSoVITSLanguage
    ) {
        self.enabled = enabled
        self.kind = kind
        self.baseURLString = baseURLString
        self.gptSoVITSReferenceAudioPath = gptSoVITSReferenceAudioPath
        self.gptSoVITSReferencePromptText = gptSoVITSReferencePromptText
        self.gptSoVITSReferencePromptLanguage = gptSoVITSReferencePromptLanguage
        self.gptSoVITSTextLanguage = gptSoVITSTextLanguage
    }

    /// Base URL trimmed of whitespace, falling back to the selected studio's loopback default when blank.
    public var resolvedBaseURLString: String {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultBaseURLString : trimmed
    }

    /// Secure storage is scoped to a studio and its validated network origin. Paths share a key.
    public var apiKeyCredentialIdentifier: String {
        get throws {
            let endpoint = try VoiceStudioEndpointPolicy.validate(
                baseURLString: resolvedBaseURLString, apiKey: nil, requireAPIKeyForRemote: false
            )
            let port = endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)
            let origin = "\(endpoint.scheme)://[\(endpoint.host)]:\(port)"
            let digest = PortableSHA256.hash(Array(origin.utf8)).map { String(format: "%02x", $0) }.joined()
            return "\(kind.apiKeyCredentialIdentifier).\(digest)"
        }
    }

    /// Returns a human-readable error if `kind == .gptSoVITS` is missing required reference settings.
    public func gptSoVITSValidationError() -> VoiceStudioError? {
        guard kind == .gptSoVITS else { return nil }
        let refPath = gptSoVITSReferenceAudioPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if refPath.isEmpty {
            return .missingGPTSoVITSConfiguration(
                detail: "Enter a reference audio clip path for GPT-SoVITS in Settings."
            )
        }
        let promptText = gptSoVITSReferencePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if promptText.isEmpty {
            return .missingGPTSoVITSConfiguration(
                detail: "Enter the reference prompt text matching your GPT-SoVITS clip in Settings."
            )
        }
        return nil
    }

    /// Voices available offline from manual studio configuration (only GPT-SoVITS when ready).
    public func configuredStaticVoices() -> [VoiceStudioVoice] {
        guard enabled, kind == .gptSoVITS, gptSoVITSValidationError() == nil else {
            return []
        }
        let lang = gptSoVITSTextLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return [VoiceStudioVoice.gptSoVITSDefaultVoice(language: lang.isEmpty ? nil : lang)]
    }
}

/// Discovered voices and server metadata returned by a voice studio backend.
public struct VoiceStudioVoiceInventory: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let kind: VoiceStudioKind
    public let baseURL: String
    public let studioVersion: String?
    public let voices: [VoiceStudioVoice]
    private let credentialDigest: [UInt8]

    public init(
        kind: VoiceStudioKind,
        baseURL: String,
        studioVersion: String? = nil,
        voices: [VoiceStudioVoice]
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.studioVersion = studioVersion
        self.voices = voices
        self.credentialDigest = Self.digest("")
    }

    init(kind: VoiceStudioKind, baseURL: String, voices: [VoiceStudioVoice], credential: String?) {
        self.kind = kind
        self.baseURL = baseURL
        self.studioVersion = nil
        self.voices = voices
        self.credentialDigest = Self.digest(credential ?? "")
    }

    func matchesCredential(_ value: String) -> Bool {
        credentialDigest == Self.digest(value)
    }

    private static func digest(_ value: String) -> [UInt8] {
        PortableSHA256.hash(Array(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    public var desktopVoices: [DesktopSpeechVoice] {
        voices.map(DesktopSpeechVoice.studio)
    }

    public var description: String {
        let versionPart = studioVersion.map { ", version=\($0)" } ?? ""
        return "VoiceStudioVoiceInventory("
            + "kind=\(kind.rawValue), baseURL=\(baseURL)\(versionPart), voices=\(voices.count))"
    }

    public var debugDescription: String { description }
}

/// Result returned by probing a studio server via Test Connection.
public struct VoiceStudioConnectionResult: Equatable, Sendable {
    public let kind: VoiceStudioKind
    public let baseURL: String
    public let studioVersion: String?
    public let voiceCount: Int?
    public let gptSoVITSConfigured: Bool
    public let detailMessage: String

    public init(
        kind: VoiceStudioKind,
        baseURL: String,
        studioVersion: String? = nil,
        voiceCount: Int? = nil,
        gptSoVITSConfigured: Bool = false,
        detailMessage: String
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.studioVersion = studioVersion
        self.voiceCount = voiceCount
        self.gptSoVITSConfigured = gptSoVITSConfigured
        self.detailMessage = detailMessage
    }
}

/// Explicit opt-in request to copy a local voice recording into Voicebox (#1821 seam).
public struct VoiceStudioProfilePushRequest: Equatable, Sendable {
    public let name: String
    public let audioData: Data
    public let audioFilename: String
    public let transcript: String?
    public let language: String?
    public let userConfirmedCopy: Bool

    public init(
        name: String,
        audioData: Data,
        audioFilename: String = "reference.wav",
        transcript: String? = nil,
        language: String? = nil,
        userConfirmedCopy: Bool
    ) {
        self.name = name
        self.audioData = audioData
        self.audioFilename = audioFilename
        self.transcript = transcript
        self.language = language
        self.userConfirmedCopy = userConfirmedCopy
    }
}

/// Actionable, sanitized errors surfaced directly to the user without falling back to system/cloud TTS.
public enum VoiceStudioError: Error, LocalizedError, Equatable, Sendable {
    case disabled
    case invalidURL(detail: String)
    case cleartextNonLoopbackDisallowed(host: String)
    case remoteHTTPSRequiresAPIKey(host: String)
    case credentialsInURLDisallowed
    case crossOriginAudioURLDisallowed(origin: String)
    case studioNotRunning(kind: VoiceStudioKind, baseURL: String)
    case tlsError(kind: VoiceStudioKind, detail: String)
    case unauthorized(kind: VoiceStudioKind, statusCode: Int)
    case httpError(kind: VoiceStudioKind, statusCode: Int, detail: String)
    case invalidResponse(kind: VoiceStudioKind, detail: String)
    case missingGPTSoVITSConfiguration(detail: String)
    case missingProfilePushConfirmation
    case unsupportedCapability(kind: VoiceStudioKind, capability: String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Local voice studio is disabled in Settings."
        case .invalidURL(let detail):
            "Invalid voice studio URL: \(detail)"
        case .cleartextNonLoopbackDisallowed(let host):
            "Refusing unencrypted http:// connection to non-loopback host '\(host)'. "
                + "Use http:// only on loopback (127.0.0.1, localhost, ::1), or switch to https:// with an API key."
        case .remoteHTTPSRequiresAPIKey(let host):
            "Remote voice studio host '\(host)' over https:// requires a configured API key in secure storage."
        case .credentialsInURLDisallowed:
            "Voice studio URLs must not contain embedded usernames or passwords. Store the API key in Settings instead."
        case .crossOriginAudioURLDisallowed(let origin):
            "Refused generated audio URL from unexpected origin '\(origin)'."
        case .studioNotRunning(let kind, let baseURL):
            "\(kind.displayName) isn't running at \(baseURL). "
                + "Start \(kind.displayName) or verify the server URL in Settings."
        case .tlsError(let kind, let detail):
            "\(kind.displayName) TLS verification failed: \(detail)"
        case .unauthorized(let kind, let statusCode):
            "\(kind.displayName) rejected authentication (HTTP \(statusCode)). "
                + "Check your \(kind.displayName) API key in Settings."
        case .httpError(let kind, let statusCode, let detail):
            "\(kind.displayName) returned HTTP \(statusCode): \(detail)"
        case .invalidResponse(let kind, let detail):
            "\(kind.displayName) returned an unexpected response: \(detail)"
        case .missingGPTSoVITSConfiguration(let detail):
            detail
        case .missingProfilePushConfirmation:
            "Confirm copying your voice recording before pushing a profile to Voicebox."
        case .unsupportedCapability(let kind, let capability):
            "\(kind.displayName) does not support \(capability)."
        }
    }
}
