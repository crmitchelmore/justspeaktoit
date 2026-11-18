import Foundation

/// A cloud AI provider that can receive audio, transcript text or text to speak,
/// with the privacy policy the consent sheet links to.
///
/// Identifiers match the canonical catalogue (`deepgram`, `openrouter`, …).
/// Display names match `PrivacyWorkflowSummary` recipients. A provider added to
/// routing without a privacy policy fails `CloudSharingProviderCatalogueTests`.
public struct CloudSharingProvider: Equatable, Sendable, Identifiable, Codable, Hashable {
    public let id: String
    public let displayName: String
    public let privacyPolicyURL: URL

    public init(id: String, displayName: String, privacyPolicyURL: URL) {
        self.id = id
        self.displayName = displayName
        self.privacyPolicyURL = privacyPolicyURL
    }
}

/// Stable provider identities and their published privacy policies.
///
/// Consent is keyed by these ids, not by display name or credential account,
/// so OpenAI transcription and OpenAI speech share one provider while the
/// data kinds stay separate.
public enum CloudSharingProviderCatalogue {
    /// Every provider a catalogue route can send to, sorted by id.
    public static let all: [CloudSharingProvider] = policies.keys.sorted().compactMap { id in
        guard let name = displayNames[id], let url = URL(string: policies[id] ?? "") else { return nil }
        return CloudSharingProvider(id: id, displayName: name, privacyPolicyURL: url)
    }

    public static func provider(id: String) -> CloudSharingProvider? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.id == trimmed }
    }

    /// The provider a model sends to for `purpose`, or nil when that send stays on the device.
    public static func provider(forModel modelID: String, purpose: ModelCredentialPurpose) -> CloudSharingProvider? {
        switch ModelCredentialResolver.requirement(for: modelID, purpose: purpose) {
        case .notRequired:
            return nil
        case .apiKey(let identifier, _):
            return provider(id: providerID(forCredential: identifier))
        }
    }

    /// Resolves the name `PrivacyWorkflowSummary` shows, including short aliases.
    public static func provider(matchingDisplayName name: String) -> CloudSharingProvider? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = all.first(where: { $0.displayName == trimmed }) { return exact }
        guard let id = displayNameAliases[trimmed] else { return nil }
        return provider(id: id)
    }

    /// `deepgram.apiKey` → `deepgram`. Shared company credentials collapse onto one provider.
    public static func providerID(forCredential identifier: String) -> String {
        var id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apiKey"
        if id.hasSuffix(suffix) {
            id.removeLast(suffix.count)
        }
        if id == "azure.speech" { return "azure" }
        if id == "openai.tts" { return "openai" }
        return id
    }

    /// The JSON Android reads. Sorted keys, trailing newline, same shape as the other catalogue exports.
    public static func androidJSON() throws -> Data {
        struct Row: Encodable {
            let displayName: String
            let id: String
            let privacyPolicyURL: String
        }
        struct Document: Encodable {
            let providers: [Row]
            let version: Int
        }
        let document = Document(
            providers: all.map {
                Row(displayName: $0.displayName, id: $0.id, privacyPolicyURL: $0.privacyPolicyURL.absoluteString)
            },
            version: 1
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    private static let displayNameAliases = [
        "Azure": "azure",
        "Google": "google",
        "Rev AI": "revai"
    ]

    private static let displayNames = [
        "alibaba": "Alibaba Model Studio",
        "anthropic": "Anthropic",
        "apple": "Apple",
        "assemblyai": "AssemblyAI",
        "azure": "Azure Speech",
        "cartesia": "Cartesia",
        "deepgram": "Deepgram",
        "elevenlabs": "ElevenLabs",
        "gladia": "Gladia",
        "google": "Google Gemini",
        "groq": "Groq",
        "meta": "Meta",
        "mistral": "Mistral",
        "modulate": "Modulate",
        "openai": "OpenAI",
        "openrouter": "OpenRouter",
        "reson8": "Reson8",
        "revai": "Rev.ai",
        "smallest": "Smallest AI",
        "soniox": "Soniox",
        "speechmatics": "Speechmatics",
        "stepfun": "StepFun",
        "xai": "xAI"
    ]

    /// Published privacy policies, checked when this catalogue was added.
    private static let policies = [
        "alibaba":
            "https://www.alibabacloud.com/help/en/legal/latest/alibaba-cloud-international-website-privacy-policy",
        "anthropic": "https://www.anthropic.com/legal/privacy",
        "apple": "https://www.apple.com/legal/privacy/",
        "assemblyai": "https://www.assemblyai.com/legal/privacy-policy",
        "azure": "https://privacy.microsoft.com/privacystatement",
        "cartesia": "https://www.cartesia.ai/legal/privacy",
        "deepgram": "https://deepgram.com/privacy",
        "elevenlabs": "https://elevenlabs.io/privacy-policy",
        "gladia": "https://www.gladia.io/privacy-notice",
        "google": "https://policies.google.com/privacy",
        "groq": "https://groq.com/privacy-policy",
        "meta": "https://www.facebook.com/privacy/policy/",
        "mistral": "https://legal.mistral.ai/terms/privacy-policy",
        "modulate": "https://www.modulate.ai/privacy-policy",
        "openai": "https://openai.com/policies/privacy-policy",
        "openrouter": "https://openrouter.ai/privacy",
        "reson8": "https://www.reson8.dev/privacy-policy",
        "revai": "https://www.rev.com/legal/privacy",
        "smallest": "https://smallest.ai/privacy-policy",
        "soniox": "https://soniox.com/policies/privacy-policy",
        "speechmatics": "https://www.speechmatics.com/legal/privacy-policy",
        "stepfun": "https://platform.stepfun.ai/docs/en/agreement/userprivacy",
        "xai": "https://x.ai/legal/privacy-policy"
    ]
}
