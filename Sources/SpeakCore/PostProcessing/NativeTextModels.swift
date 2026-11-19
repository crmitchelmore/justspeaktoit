import Foundation

/// A text provider called directly through its own OpenAI-compatible
/// `chat/completions` endpoint with the user's key for that provider.
public struct NativeTextProvider: Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let chatCompletionsURL: URL
    /// OpenAI's GPT-5 and later reasoning models reject any non-default temperature.
    public let sendsTemperature: Bool
    /// OpenAI names the output limit `max_completion_tokens`; the others accept `max_tokens`.
    public let usesMaxCompletionTokens: Bool
    /// Output limit sent when the caller sets none. Anthropic rejects requests without one.
    public var defaultMaxTokens: Int?

    public var credentialIdentifier: String { ProviderCredentialCatalogue.apiKeyIdentifier(for: id) }
}

/// Curated cleanup models served by their own provider rather than OpenRouter.
///
/// Native selections use the `native/<provider>/<model>` namespace. Unprefixed
/// catalogue identifiers such as `openai/gpt-6-luna` are OpenRouter slugs and
/// stay OpenRouter selections, so saved choices never change route silently.
public enum NativeTextModels {
    public static let prefix = "native/"

    /// Claude through Anthropic's OpenAI-compatible endpoint. Claude 4.7 and later
    /// reject a temperature below 1, so none is sent.
    public static let anthropic = NativeTextProvider(
        id: "anthropic", displayName: "Anthropic",
        chatCompletionsURL: URL(string: "https://api.anthropic.com/v1/chat/completions")!,
        sendsTemperature: false, usesMaxCompletionTokens: false, defaultMaxTokens: 8_192
    )
    public static let openAI = NativeTextProvider(
        id: "openai", displayName: "OpenAI",
        chatCompletionsURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
        sendsTemperature: false, usesMaxCompletionTokens: true
    )
    public static let google = NativeTextProvider(
        id: "google", displayName: "Google Gemini",
        chatCompletionsURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!,
        sendsTemperature: true, usesMaxCompletionTokens: false
    )
    public static let groq = NativeTextProvider(
        id: "groq", displayName: "Groq",
        chatCompletionsURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
        sendsTemperature: true, usesMaxCompletionTokens: false
    )
    public static let mistral = NativeTextProvider(
        id: "mistral", displayName: "Mistral",
        chatCompletionsURL: URL(string: "https://api.mistral.ai/v1/chat/completions")!,
        sendsTemperature: true, usesMaxCompletionTokens: false
    )

    /// Every native text provider. Pickers sort by provider name, then model name.
    public static let providers: [NativeTextProvider] = [anthropic, openAI, google, groq, mistral]

    public static func selectionID(provider: NativeTextProvider, model: String) -> String {
        "\(prefix)\(provider.id)/\(model)"
    }

    /// The provider and provider-native model for a native selection, or nil
    /// for every other identifier (including OpenRouter slugs).
    public static func route(for selection: String) -> (provider: NativeTextProvider, model: String)? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let rest = trimmed.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let providerID = String(rest[..<slash])
        let model = String(rest[rest.index(after: slash)...])
        guard !model.isEmpty, let provider = providers.first(where: { $0.id == providerID }) else { return nil }
        return (provider, model)
    }

    public static func isNative(_ selection: String) -> Bool { route(for: selection) != nil }

    // Native IDs and standard rates verified 12 November 2026 against each provider's
    // model docs; superseded entries live in `CleanupModelRemovals`.
    public static let postProcessing: [ModelCatalog.Option] = [
        option(anthropic, "claude-haiku-5-5", "Claude Haiku 5.5",
               "Anthropic's fastest, lowest-cost Claude, direct from Anthropic.",
               tags: [.fast, .cheap],
               pricing: .init(promptPerMTokens: 0.10, completionPerMTokens: 0.50), context: 1_000_000),
        option(anthropic, "claude-sonnet-5-5", "Claude Sonnet 5.5",
               "Excellent structure and tone preservation, direct from Anthropic.",
               tags: [.quality, .leading],
               pricing: .init(promptPerMTokens: 2.0, completionPerMTokens: 10.0), context: 1_000_000),
        option(openAI, "gpt-6-luna", "GPT-6 Luna", "Cost-efficient GPT-6, direct from OpenAI.",
               tags: [.cheap], pricing: .init(promptPerMTokens: 0.10, completionPerMTokens: 0.50),
               context: 1_050_000),
        option(openAI, "gpt-6.1-terra", "GPT-6.1 Terra", "Balanced GPT-6.1 quality and cost, direct from OpenAI.",
               tags: [.quality], pricing: .init(promptPerMTokens: 1.0, completionPerMTokens: 5.0),
               context: 1_050_000),
        option(openAI, "gpt-6.1-sol", "GPT-6.1 Sol", "OpenAI's middle GPT-6 tier, direct from OpenAI.",
               tags: [.quality], pricing: .init(promptPerMTokens: 2.0, completionPerMTokens: 10.0),
               context: 1_050_000),
        option(google, "gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite",
               "Low-cost, long-context cleanup, direct from Google.",
               latency: 400, tier: .fast, tags: [.fast, .cheap],
               pricing: .init(promptPerMTokens: 0.25, completionPerMTokens: 1.5), context: 1_048_576),
        option(google, "gemini-3.5-flash-lite", "Gemini 3.5 Flash Lite",
               "Newest Gemini Flash Lite, direct from Google.",
               tags: [.fast],
               pricing: .init(promptPerMTokens: 0.30, completionPerMTokens: 2.5), context: 1_048_576),
        option(groq, "openai/gpt-oss-120b", "GPT-OSS 120B", "Open-weight model on Groq's low-latency hardware.",
               latency: 400, tier: .fast, tags: [.fast], context: 131_072),
        option(groq, "openai/gpt-oss-20b", "GPT-OSS 20B", "Very fast, inexpensive open-weight cleanup on Groq.",
               latency: 250, tier: .instant, tags: [.fast, .cheap],
               pricing: .init(promptPerMTokens: 0.075, completionPerMTokens: 0.30), context: 131_072),
        option(mistral, "mistral-small-latest", "Mistral Small", "Inexpensive formatting, direct from Mistral.",
               latency: 450, tier: .fast, tags: [.fast, .cheap])
    ]

    private static func option(
        _ provider: NativeTextProvider, _ model: String, _ name: String, _ description: String,
        latency: Int? = nil, tier: LatencyTier = .medium, tags: [ModelCatalog.Tag],
        pricing: ModelCatalog.Pricing? = nil, context: Int? = nil
    ) -> ModelCatalog.Option {
        .init(
            id: selectionID(provider: provider, model: model), displayName: name, description: description,
            estimatedLatencyMs: latency, latencyTier: tier, tags: tags, pricing: pricing, contextLength: context
        )
    }
}

/// Where a chat request for a selection is sent. Native selections go to their
/// provider; every other identifier keeps the existing OpenRouter route.
struct ChatCompletionTarget: Equatable {
    let url: URL
    let model: String
    let sendsTemperature: Bool
    let usesMaxCompletionTokens: Bool
    var defaultMaxTokens: Int?
    let isOpenRouter: Bool

    static func resolve(_ selection: String) throws -> ChatCompletionTarget {
        if let route = NativeTextModels.route(for: selection) {
            return .init(
                url: route.provider.chatCompletionsURL, model: route.model,
                sendsTemperature: route.provider.sendsTemperature,
                usesMaxCompletionTokens: route.provider.usesMaxCompletionTokens,
                defaultMaxTokens: route.provider.defaultMaxTokens, isOpenRouter: false
            )
        }
        return .init(
            url: OpenRouterService.baseURL.appendingPathComponent("chat/completions"),
            model: try CleanupModelSelection.requestModel(selection),
            sendsTemperature: true, usesMaxCompletionTokens: false, defaultMaxTokens: nil, isOpenRouter: true
        )
    }
}

public enum NativeTextModelError: LocalizedError, Equatable {
    case apiKeyMissing(providerName: String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing(let providerName):
            return "Add your \(providerName) API key to use this model, or choose a model via OpenRouter."
        }
    }
}
