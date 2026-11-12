import Foundation

/// A cleanup model taken out of the catalogue because a newer model from the same
/// provider is both cheaper and at least as capable, or because its provider has
/// replaced it. Saved selections, profile overrides and in-flight requests move to
/// `successorID` straight away; the successor always keeps the same route (native
/// selections stay with their provider's own key, OpenRouter slugs stay on OpenRouter).
public struct RemovedCleanupModel: Sendable, Equatable {
    public let id: String
    /// Name shown for History entries recorded with this model.
    public let displayName: String
    public let successorID: String
}

/// Rates and lineups checked 12 November 2026 against https://openrouter.ai/api/v1/models,
/// https://developers.openai.com/api/docs/pricing, https://platform.claude.com/docs/en/models/overview
/// and https://ai.google.dev/gemini-api/docs/deprecations. See Docs/cleanup-model-upgrades-2026-11.md.
public enum CleanupModelRemovals {
    private static func native(_ provider: NativeTextProvider, _ model: String) -> String {
        NativeTextModels.selectionID(provider: provider, model: model)
    }

    public static let all: [RemovedCleanupModel] = [
        // OpenAI via OpenRouter. GPT-6 Luna ($0.10/$0.50) and GPT-6.1 Terra ($1/$5) and
        // Sol ($2/$10) undercut every GPT-5.x entry of the same or lower tier.
        .init(id: "openai/gpt-5-mini", displayName: "GPT-5 Mini", successorID: "openai/gpt-6-luna"),
        .init(id: "openai/gpt-5.4-nano", displayName: "GPT-5.4 Nano", successorID: "openai/gpt-6-luna"),
        .init(id: "openai/gpt-5.4-mini", displayName: "GPT-5.4 Mini", successorID: "openai/gpt-6-luna"),
        .init(id: "openai/gpt-5.6-luna", displayName: "GPT-5.6 Luna", successorID: "openai/gpt-6-luna"),
        .init(id: "openai/gpt-5.6-terra", displayName: "GPT-5.6 Terra", successorID: "openai/gpt-6.1-terra"),
        .init(id: "openai/gpt-5.6-sol", displayName: "GPT-5.6 Sol", successorID: "openai/gpt-6.1-sol"),
        .init(id: "openai/gpt-5.5", displayName: "GPT-5.5", successorID: "openai/gpt-6.1-sol"),
        .init(id: "openai/gpt-5.4", displayName: "GPT-5.4", successorID: "openai/gpt-6.1-sol"),
        // Anthropic via OpenRouter: the 5.5 generation is cheaper than 4.5/4.6.
        .init(id: "anthropic/claude-haiku-4.5", displayName: "Claude Haiku 4.5",
              successorID: "anthropic/claude-haiku-5.5"),
        .init(id: "anthropic/claude-sonnet-4.6", displayName: "Claude Sonnet 4.6",
              successorID: "anthropic/claude-sonnet-5.5"),
        // Google routes Gemini 2.5 Flash to 3.5 Flash-Lite (same rates) from 1 December 2026.
        .init(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash",
              successorID: "google/gemini-3.5-flash-lite"),
        // Qwen3.8 Flash ($0.15/$0.47) replaces the older Qwen3.6 entries; Llama 4 Scout
        // (April 2025) has no Meta successor and is outclassed at a similar price.
        .init(id: "qwen/qwen3.6-flash", displayName: "Qwen3.6 Flash", successorID: "qwen/qwen3.8-flash"),
        .init(id: "qwen/qwen3.6-35b-a3b", displayName: "Qwen3.6 35B A3B", successorID: "qwen/qwen3.8-flash"),
        .init(id: "meta-llama/llama-4-scout", displayName: "Llama 4 Scout", successorID: "qwen/qwen3.8-flash"),

        // Direct (native) routes keep their provider and key.
        .init(id: native(NativeTextModels.openAI, "gpt-5-mini"), displayName: "GPT-5 Mini",
              successorID: native(NativeTextModels.openAI, "gpt-6-luna")),
        .init(id: native(NativeTextModels.openAI, "gpt-5.4-mini"), displayName: "GPT-5.4 Mini",
              successorID: native(NativeTextModels.openAI, "gpt-6-luna")),
        .init(id: native(NativeTextModels.anthropic, "claude-haiku-4-5"), displayName: "Claude Haiku 4.5",
              successorID: native(NativeTextModels.anthropic, "claude-haiku-5-5")),
        .init(id: native(NativeTextModels.anthropic, "claude-sonnet-4-6"), displayName: "Claude Sonnet 4.6",
              successorID: native(NativeTextModels.anthropic, "claude-sonnet-5-5")),
        .init(id: native(NativeTextModels.google, "gemini-2.5-flash"), displayName: "Gemini 2.5 Flash",
              successorID: native(NativeTextModels.google, "gemini-3.5-flash-lite")),
        // Groq shut Llama 3.1 8B Instant down on 2026-08-16 (console.groq.com/docs/deprecations).
        .init(id: native(NativeTextModels.groq, "llama-3.1-8b-instant"), displayName: "Llama 3.1 8B Instant",
              successorID: native(NativeTextModels.groq, "openai/gpt-oss-20b"))
    ]

    private static let byID: [String: RemovedCleanupModel] = Dictionary(
        all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )

    public static func removal(for id: String) -> RemovedCleanupModel? {
        byID[id.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

public extension ModelCatalog {
    /// The cleanup model a saved selection should run now: the successor of a
    /// removed or shut-down model, otherwise the selection unchanged.
    static func currentPostProcessingModel(_ identifier: String, at date: Date = Date()) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let removal = CleanupModelRemovals.removal(for: trimmed) { return removal.successorID }
        return ModelRetirements.successor(for: trimmed, mode: .postProcessing, at: date) ?? identifier
    }
}
