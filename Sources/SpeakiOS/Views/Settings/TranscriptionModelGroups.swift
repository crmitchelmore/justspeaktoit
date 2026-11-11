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

    /// Buckets catalogue options by provider; sections and their models are
    /// alphabetical (provider, then model name). Options whose id doesn't
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
        return order.map { key in
            LiveModelGroup(
                id: key, title: titles[key] ?? key,
                options: ModelPickerGrouping.sortedByProvider(buckets[key] ?? [], purpose: .liveTranscription)
            )
        }
        .sorted { ModelPickerGrouping.ordered($0.title, $1.title) ?? false }
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
        return grouped.keys.map { provider in
            BatchModelGroup(
                id: provider,
                title: providerDisplayName(provider),
                options: ModelPickerGrouping.sortedByProvider(
                    grouped[provider, default: []], purpose: .batchTranscription
                )
            )
        }
        .sorted { ModelPickerGrouping.ordered($0.title, $1.title) ?? ($0.id < $1.id) }
    }

    private static func providerDisplayName(_ provider: String) -> String {
        if let speechProvider = FileSpeechProvider(rawValue: provider) { return speechProvider.metadata.displayName }
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
