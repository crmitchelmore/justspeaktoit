import Foundation

// MARK: - Data kinds

/// A kind of personal data that a cloud AI provider can receive.
///
/// App Store guideline 5.1.2(i) and Google Play's User Data policy require
/// explicit permission per recipient before this content leaves the device, so
/// consent is recorded per provider and per kind: allowing a provider to
/// clean up transcript text does not allow it to receive recorded audio.
public enum CloudSharedDataKind: String, CaseIterable, Codable, Sendable, Comparable {
    /// Microphone or recorded audio, sent for transcription.
    case audio
    /// Transcript text, sent for clean-up (post-processing).
    case transcriptText
    /// Text sent to be read aloud.
    case textToSpeak

    public var title: String {
        switch self {
        case .audio: return "Your audio recordings"
        case .transcriptText: return "Your transcript text"
        case .textToSpeak: return "Text you ask to be read aloud"
        }
    }

    /// Why the provider receives this kind of data.
    public var purpose: String {
        switch self {
        case .audio: return "to transcribe what you say"
        case .transcriptText: return "to clean up your transcripts"
        case .textToSpeak: return "to turn it into speech"
        }
    }

    public static func < (lhs: CloudSharedDataKind, rhs: CloudSharedDataKind) -> Bool {
        let order = allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Providers

/// A third-party AI provider that can receive content, with the policy a user
/// reads before allowing it.
public struct CloudSharingProvider: Equatable, Hashable, Sendable, Identifiable {
    /// Canonical provider ID: the first component of the provider's credential
    /// identifier (`openai`, `azure`, `openrouter`, ...).
    public let id: String
    public let displayName: String
    /// `nil` only for a provider missing from `CloudSharingProviderCatalogue`;
    /// `CloudSharingConsentTests` fails when a catalogued provider has none.
    public let privacyPolicyURL: URL?

    public init(id: String, displayName: String, privacyPolicyURL: URL?) {
        self.id = id
        self.displayName = displayName
        self.privacyPolicyURL = privacyPolicyURL
    }
}

/// Every cloud provider the transcription, clean-up and voice catalogues can
/// route content to, with its privacy policy.
public enum CloudSharingProviderCatalogue {
    public static let all: [CloudSharingProvider] = [
        provider(
            "alibaba", "Alibaba Model Studio",
            "https://www.alibabacloud.com/help/en/legal/latest/alibaba-cloud-international-website-privacy-policy"
        ),
        provider("anthropic", "Anthropic", "https://www.anthropic.com/legal/privacy"),
        provider("assemblyai", "AssemblyAI", "https://www.assemblyai.com/legal/privacy-policy"),
        provider("azure", "Azure Speech", "https://privacy.microsoft.com/privacystatement"),
        provider("cartesia", "Cartesia", "https://cartesia.ai/legal/privacy"),
        provider("deepgram", "Deepgram", "https://deepgram.com/privacy"),
        provider("elevenlabs", "ElevenLabs", "https://elevenlabs.io/privacy-policy"),
        provider("gladia", "Gladia", "https://www.gladia.io/privacy-policy"),
        provider("google", "Google Gemini", "https://policies.google.com/privacy"),
        provider("groq", "Groq", "https://groq.com/privacy-policy/"),
        provider("meta", "Meta", "https://www.facebook.com/privacy/policy/"),
        provider("mistral", "Mistral", "https://mistral.ai/terms#privacy-policy"),
        provider("modulate", "Modulate", "https://www.modulate.ai/privacy-policy"),
        provider("openai", "OpenAI", "https://openai.com/policies/privacy-policy/"),
        provider("openrouter", "OpenRouter", "https://openrouter.ai/privacy"),
        provider("reson8", "Reson8", "https://reson8.dev/privacy-policy"),
        provider("revai", "Rev.ai", "https://www.rev.com/about/privacy"),
        provider("smallest", "Smallest AI", "https://smallest.ai/privacy-policy"),
        provider("soniox", "Soniox", "https://soniox.com/policies/privacy-policy"),
        provider("speechmatics", "Speechmatics", "https://www.speechmatics.com/privacy-policy"),
        provider("stepfun", "StepFun", "https://stepfun.ai/privacy-policy"),
        provider("xai", "xAI", "https://x.ai/legal/privacy-policy")
    ]

    public static func provider(id: String) -> CloudSharingProvider? {
        all.first { $0.id == id }
    }

    /// `openai.tts.apiKey` → `openai`, `azure.speech.apiKey` → `azure`.
    public static func providerID(forCredentialIdentifier identifier: String) -> String {
        let trimmed = identifier.hasSuffix(".apiKey") ? String(identifier.dropLast(".apiKey".count)) : identifier
        return trimmed.split(separator: ".").first.map(String.init) ?? trimmed
    }

    /// The catalogued provider for an ID, or a link-less entry named
    /// `fallbackName` so an uncatalogued provider still needs consent.
    public static func resolve(id: String, fallbackName: String) -> CloudSharingProvider {
        provider(id: id) ?? CloudSharingProvider(id: id, displayName: fallbackName, privacyPolicyURL: nil)
    }

    private static func provider(_ id: String, _ name: String, _ url: String) -> CloudSharingProvider {
        CloudSharingProvider(id: id, displayName: name, privacyPolicyURL: URL(string: url))
    }
}

// MARK: - Requests

/// What one provider would receive under the current settings.
public struct CloudSharingRequest: Equatable, Hashable, Sendable, Identifiable {
    public let provider: CloudSharingProvider
    /// Sorted in `CloudSharedDataKind` order, without duplicates.
    public let kinds: [CloudSharedDataKind]

    public var id: String { provider.id }

    public init(provider: CloudSharingProvider, kinds: some Sequence<CloudSharedDataKind>) {
        self.provider = provider
        self.kinds = Set(kinds).sorted()
    }

    /// "Your audio recordings, to transcribe what you say."
    public var kindLines: [String] { kinds.map { "\($0.title), \($0.purpose)." } }
}

// MARK: - Consent

/// Which providers the user has allowed to receive which kinds of content.
///
/// Recorded per device and never synced or transferred: consent given on one
/// device is not consent for another. The Apple "on device or Apple" Speech
/// fallback is not covered here; the system Speech Recognition permission
/// prompt asks for that.
public struct CloudSharingConsent: Equatable, Sendable {
    public private(set) var grants: [String: Set<CloudSharedDataKind>]

    public init(grants: [String: Set<CloudSharedDataKind>] = [:]) {
        self.grants = grants.filter { !$0.value.isEmpty }
    }

    public func allows(providerID: String, kind: CloudSharedDataKind) -> Bool {
        grants[providerID]?.contains(kind) == true
    }

    /// The part of each request the user has not allowed yet, dropping
    /// requests that are fully allowed.
    public func missing(_ requests: [CloudSharingRequest]) -> [CloudSharingRequest] {
        requests.compactMap { request in
            let missingKinds = request.kinds.filter { !allows(providerID: request.provider.id, kind: $0) }
            return missingKinds.isEmpty ? nil : CloudSharingRequest(provider: request.provider, kinds: missingKinds)
        }
    }

    public mutating func grant(_ requests: [CloudSharingRequest]) {
        for request in requests {
            grants[request.provider.id, default: []].formUnion(request.kinds)
        }
    }

    public mutating func withdraw(providerID: String) {
        grants[providerID] = nil
    }

    public mutating func withdrawAll() {
        grants = [:]
    }

    /// Allowed providers with their kinds, sorted by display name.
    public var allowedRequests: [CloudSharingRequest] {
        grants.map { id, kinds in
            CloudSharingRequest(provider: CloudSharingProviderCatalogue.resolve(id: id, fallbackName: id), kinds: kinds)
        }
        .sorted {
            $0.provider.displayName.localizedCaseInsensitiveCompare($1.provider.displayName) == .orderedAscending
        }
    }
}

// MARK: Deriving requests

public extension CloudSharingConsent {
    /// The kind of content each workflow row sends.
    static func kind(forRowID rowID: String) -> CloudSharedDataKind? {
        switch rowID {
        case "transcription": return .audio
        case "postProcessing": return .transcriptText
        case "voiceOutput": return .textToSpeak
        default: return nil
        }
    }

    /// Every provider that receives content under `summary`, and what it gets.
    /// Rows without a `providerID` (on device, off, or the Apple Speech
    /// fallback) need no consent here.
    static func requests(for summary: PrivacyWorkflowSummary) -> [CloudSharingRequest] {
        merged(summary.rows.compactMap { row in
            guard let providerID = row.providerID, let name = row.destination.providerName,
                  let kind = kind(forRowID: row.id) else { return nil }
            return CloudSharingRequest(
                provider: CloudSharingProviderCatalogue.resolve(id: providerID, fallbackName: name),
                kinds: [kind]
            )
        })
    }

    /// The request for one model use outside the summary (a file
    /// transcription, live polish, read aloud, Compare Models), or `nil` when
    /// the model runs on device.
    static func request(
        forModel modelID: String,
        purpose: ModelCredentialPurpose
    ) -> CloudSharingRequest? {
        guard case .apiKey(let identifier, let providerName) = ModelCredentialResolver.requirement(
            for: modelID, purpose: purpose
        ) else { return nil }
        return request(credentialIdentifier: identifier, providerName: providerName, kind: kind(for: purpose))
    }

    /// The request for a provider known by its credential, such as a voice
    /// output provider that the model resolver does not route.
    static func request(
        credentialIdentifier: String,
        providerName: String,
        kind: CloudSharedDataKind
    ) -> CloudSharingRequest {
        let id = CloudSharingProviderCatalogue.providerID(forCredentialIdentifier: credentialIdentifier)
        return CloudSharingRequest(
            provider: CloudSharingProviderCatalogue.resolve(id: id, fallbackName: providerName),
            kinds: [kind]
        )
    }

    static func kind(for purpose: ModelCredentialPurpose) -> CloudSharedDataKind {
        switch purpose {
        case .liveTranscription, .batchTranscription: return .audio
        case .postProcessing: return .transcriptText
        case .voiceOutput: return .textToSpeak
        }
    }

    /// One request per provider, kinds combined, in first-seen order.
    static func merged(_ requests: [CloudSharingRequest]) -> [CloudSharingRequest] {
        var order: [String] = []
        var providers: [String: CloudSharingProvider] = [:]
        var kinds: [String: Set<CloudSharedDataKind>] = [:]
        for request in requests {
            if providers[request.provider.id] == nil {
                order.append(request.provider.id)
                providers[request.provider.id] = request.provider
            }
            kinds[request.provider.id, default: []].formUnion(request.kinds)
        }
        return order.compactMap { id in
            providers[id].map { CloudSharingRequest(provider: $0, kinds: kinds[id] ?? []) }
        }
    }
}

// MARK: Copy

public extension CloudSharingConsent {
    static let sheetTitle = "Allow sharing with an AI provider?"
    static let allowTitle = "Allow"
    static let useOnDeviceTitle = "Use on-device instead"
    static let notNowTitle = "Not now"
    static let withdrawalTitle = "AI providers you allowed"
    static let withdrawalFooter = "Withdrawing stops the app sending that provider anything until you allow it again. "
        + "It does not delete data the provider already received; its privacy policy explains how to ask."
    static let emptyWithdrawalText = "You haven't allowed any AI provider to receive your content."

    /// The sheet's opening sentence; `{providers}` and `{service}` are filled
    /// in. Exported to Android so both say the same thing.
    static let sheetIntroTemplate = "Your current settings send personal data to {providers}, {service}. "
        + "Nothing is sent until you allow it. You can withdraw this in Privacy settings."
    static let singleServiceName = "a third-party AI service"
    static let pluralServiceName = "third-party AI services"
    static let blockedMessageTemplate = "Open Just Speak to It to allow sending your content to {providers}, "
        + "or switch to on-device."

    static func sheetIntro(for requests: [CloudSharingRequest]) -> String {
        sheetIntroTemplate
            .replacingOccurrences(of: "{providers}", with: providerNames(requests))
            .replacingOccurrences(of: "{service}", with: requests.count == 1 ? singleServiceName : pluralServiceName)
    }

    /// A one-line reason for surfaces that cannot show the sheet (Shortcuts,
    /// the keyboard, a notification or a status line).
    static func blockedMessage(for requests: [CloudSharingRequest]) -> String {
        blockedMessageTemplate.replacingOccurrences(of: "{providers}", with: providerNames(requests))
    }

    private static func providerNames(_ requests: [CloudSharingRequest]) -> String {
        PrivacyWorkflowSummary.formattedList(requests.map(\.provider.displayName))
    }
}

// MARK: - Persistence

extension CloudSharingConsent: Codable {
    private struct Stored: Codable {
        var version: Int
        var grants: [String: [CloudSharedDataKind]]
    }

    public init(from decoder: Decoder) throws {
        let stored = try Stored(from: decoder)
        self.init(grants: stored.grants.mapValues(Set.init))
    }

    public func encode(to encoder: Encoder) throws {
        try Stored(version: 1, grants: grants.mapValues { $0.sorted() }).encode(to: encoder)
    }
}
