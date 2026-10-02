#if os(iOS)
import Foundation
import SpeakCore

// MARK: - Settings View

/// A provider-titled group of live-transcription models, so the picker can list
/// a growing catalogue in tidy per-provider sections instead of one long list.
struct LiveModelGroup: Identifiable {
    let id: String
    let title: String
    let options: [ModelCatalog.Option]

    /// Buckets catalogue options by provider, preserving first-appearance order
    /// so the sections stay stable as models are added. Options whose id doesn't
    /// resolve to a known provider are still shown (grouped by their id prefix)
    /// rather than silently dropped.
    static func grouped(_ options: [ModelCatalog.Option]) -> [LiveModelGroup] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [ModelCatalog.Option]] = [:]
        for option in options {
            let route = LiveTranscriptionRouting.route(for: option.id)
            let key = route?.provider.rawValue ?? String(option.id.prefix { $0 != "/" })
            if buckets[key] == nil {
                order.append(key)
                titles[key] = route?.provider.displayName ?? key.capitalized
            }
            buckets[key, default: []].append(option)
        }
        return order.map { LiveModelGroup(id: $0, title: titles[$0] ?? $0, options: buckets[$0] ?? []) }
    }
}

struct BatchModelGroup: Identifiable {
    let id: String
    let title: String
    let options: [ModelCatalog.Option]

    static func grouped(_ options: [ModelCatalog.Option]) -> [BatchModelGroup] {
        let grouped = Dictionary(grouping: options) { option in
            String(option.id.prefix { $0 != "/" })
        }
        return grouped.keys.sorted().map { provider in
            BatchModelGroup(
                id: provider,
                title: providerDisplayName(provider),
                options: grouped[provider, default: []]
            )
        }
    }

    private static func providerDisplayName(_ provider: String) -> String {
        let names = [
            "openai": "OpenAI",
            "groq": "Groq",
            "revai": "Rev.ai",
            "mistral": "Mistral",
            "soniox": "Soniox",
            "deepgram": "Deepgram",
            "assemblyai": "AssemblyAI",
            "elevenlabs": "ElevenLabs",
            "modulate": "Modulate",
            "google": "Google via OpenRouter"
        ]
        return names[provider] ?? provider.capitalized
    }
}

#endif
