import Foundation

/// Published per-minute list prices for speech-to-text models, used to put an
/// estimated cost next to each Compare Models result.
///
/// These are estimates. Providers bill in different units (seconds, hours,
/// audio tokens) and change list prices without notice, so every figure here
/// is the public pay-as-you-go rate converted to US dollars per audio minute,
/// last reviewed on `lastReviewed`. Models without a reliable model-only
/// per-minute estimate (token-billed sessions, regional prices, previews) return `nil` and the
/// UI shows no cost rather than a guess. On-device models cost nothing.
public enum TranscriptionPricing {
    /// When the table below was last checked against provider pricing pages.
    public static let lastReviewed = "2026-11"

    /// Estimated US-dollar cost of transcribing `durationSeconds` of audio
    /// with `modelID`, or `nil` when no rate is known.
    public static func estimatedCostUSD(modelID: String, durationSeconds: Double) -> Decimal? {
        guard durationSeconds > 0, let perMinute = pricePerMinuteUSD(modelID: modelID) else { return nil }
        return Decimal(durationSeconds) / 60 * perMinute
    }

    /// The same estimate shaped as a session cost, for live results whose
    /// provider reports none. Seconds of audio stand in for input tokens.
    public static func estimatedCost(modelID: String, durationSeconds: Double) -> ChatCostBreakdown? {
        guard let total = estimatedCostUSD(modelID: modelID, durationSeconds: durationSeconds) else { return nil }
        return ChatCostBreakdown(inputTokens: Int(durationSeconds), outputTokens: 0, totalCost: total, currency: "USD")
    }

    /// The list price per audio minute for `modelID`, or `nil` when unknown.
    public static func pricePerMinuteUSD(modelID: String) -> Decimal? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFree(trimmed) { return .zero }
        if let exact = exactRates[trimmed] { return exact }
        return prefixRates.first { trimmed.hasPrefix($0.prefix) }?.rate
    }

    /// Whether the model runs on this machine and therefore has no usage fee.
    public static func isFree(_ modelID: String) -> Bool {
        modelID.hasPrefix("local/") || modelID.hasPrefix("apple/")
    }

    /// Formats a cost for display, e.g. "$0.0012". Sub-cent amounts keep four
    /// decimals so the cheap models do not all round to "$0.00".
    public static func formatted(_ cost: Decimal) -> String {
        if cost == .zero { return "$0" }
        let fractionDigits = cost < Decimal(string: "0.01")! ? 4 : 3
        var value = cost
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, fractionDigits, .plain)
        return "$\(rounded)"
    }

    private static func rate(_ perMinute: String) -> Decimal {
        Decimal(string: perMinute)!
    }

    private static func perHour(_ perHour: String) -> Decimal {
        Decimal(string: perHour)! / 60
    }

    // Exact catalogue ids first so a model priced differently from its
    // provider's default (a "mini" or "turbo" tier) is not swallowed by the
    // prefix table below.
    private static let exactRates: [String: Decimal] = [
        // Pulse Pro Standard plan, checked 2026-10-13 on its official model card.
        FileSpeechProvider.smallest.modelID: rate("0.004"),
        // OpenAI: $0.006/min for Whisper and gpt-4o-transcribe, $0.003/min for
        // the mini tier. The realtime transcription sessions are billed on
        // audio input tokens, which the same per-minute figures approximate.
        "openai/whisper-1": rate("0.006"),
        "openai/gpt-4o-transcribe": rate("0.006"),
        "openai/gpt-4o-mini-transcribe": rate("0.003"),
        "openai/gpt-4o-transcribe-streaming": rate("0.006"),
        "openai/gpt-4o-mini-transcribe-streaming": rate("0.003"),
        // GPT Transcribe and GPT Live Transcribe bill per audio minute:
        // https://developers.openai.com/api/docs/models/gpt-transcribe and
        // https://developers.openai.com/api/docs/models/gpt-live-transcribe (checked 2026-11-02).
        OpenAITranscriptionModels.gptTranscribeCatalogID: rate("0.0045"),
        OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID: rate("0.017"),
        // Mode-specific pay-as-you-go rates: https://deepgram.com/pricing
        // (checked 2026-11-11). The streaming promotions have ended; Nova-3 is
        // the monolingual rate. Nova, Enhanced and Base are no longer listed,
        // so their last published rates are kept.
        "deepgram/nova-3": rate("0.0043"),
        "deepgram/nova-3-streaming": rate("0.0077"),
        "deepgram/flux-general-en-streaming": rate("0.0077"),
        "deepgram/flux-general-multi-streaming": rate("0.0078"),
        "deepgram/nova": rate("0.0058"),
        "deepgram/enhanced": rate("0.0165"),
        "deepgram/base": rate("0.0145"),
        // https://elevenlabs.io/pricing/api (checked 2026-11-11): Scribe v3, v2
        // and v2 Medical share one batch rate; v3 Live and v2 Realtime share one.
        ModelCatalog.elevenLabsScribeV3BatchID: perHour("0.20"),
        "elevenlabs/scribe_v2": perHour("0.20"),
        ModelCatalog.elevenLabsScribeV2MedicalBatchID: perHour("0.20"),
        ModelCatalog.elevenLabsScribeV3LiveID: perHour("0.22"),
        "elevenlabs/scribe-v2-streaming": perHour("0.22"),
        // Modulate Velma: $0.03/hr batch, $0.025/hr English very-fast,
        // $0.06/hr streaming (matches ModulateTranscriptionProvider).
        "modulate/velma-2-stt-batch": perHour("0.03"),
        "modulate/velma-2-stt-batch-english-vfast": perHour("0.025"),
        "modulate/velma-2-stt-streaming": perHour("0.06"),
        // https://www.assemblyai.com/pricing (checked 2026-10-13).
        // Streaming bills session duration, so audio-duration estimates exclude idle time.
        AssemblyAIModels.universal36ProStreamingID: perHour("0.45"),
        AssemblyAIModels.universal35ProStreamingID: perHour("0.45"),
        AssemblyAIModels.universal35ProBatchID: perHour("0.21"),
        AssemblyAIModels.universal2BatchID: perHour("0.15"),
        // OpenRouter removed the free Inkling routes; History recorded on them stays free.
        "thinkingmachines/inkling:free": .zero,
        "thinkingmachines/inkling-small:free": .zero,
        // Paid audio-chat routes are token-billed: no per-minute estimate without usage.
        // Soniox: $0.10/hr async, $0.12/hr real-time (unchanged from v5).
        // History recorded under v5 keeps its estimate.
        "soniox/stt-async-v6": perHour("0.10"),
        "soniox/stt-rt-v6-streaming": perHour("0.12"),
        "soniox/stt-async-v5": perHour("0.10"),
        "soniox/stt-rt-v5-streaming": perHour("0.12"),
        // Groq Whisper large-v3-turbo: $0.04 per audio hour.
        "groq/whisper-large-v3-turbo": perHour("0.04"),
        // Voxtral Mini Transcribe 2 (`voxtral-mini-latest`): $0.003/min.
        // https://docs.mistral.ai/models/voxtral-mini-transcribe-26-02
        "mistral/voxtral-mini-latest": rate("0.003"),
        // Voxtral 3 public-preview model cards, checked 2026-10-20:
        // https://docs.mistral.ai/models/voxtral-mini-transcribe-3-0
        // https://docs.mistral.ai/models/voxtral-small-transcribe-3-0
        // https://docs.mistral.ai/models/voxtral-mini-transcribe-realtime-3-0
        MistralVoxtral3.miniBatchID: rate("0.0035"),
        MistralVoxtral3.smallBatchID: rate("0.004"),
        MistralVoxtral3.realtimeID: rate("0.008"),
        // Google Gemini audio input: $0.50 per 1M tokens for 3.1 Flash-Lite and
        // $1.00 for 2.5 Flash, at 32 audio tokens per second.
        "google/gemini-3.1-flash-lite": rate("0.00096"),
        "google/gemini-2.5-flash": rate("0.00192"),
        // Gladia: $0.612/hr pre-recorded, $0.75/hr real-time.
        "gladia/solaria-1-streaming": perHour("0.75"),
        // MAI-Transcribe-2 launch price: https://microsoft.ai/news/mai-transcribe-2
        // (checked 2026-10-01). The offer ends on 31 December 2026 and no later
        // rate is published yet; like every rate here this is maintained by
        // hand, so replace it when Microsoft publishes the standard price.
        AzureTranscriptionModels.mai2: perHour("0.10"),
        // https://microsoft.ai/news/our-first-streaming-transcription-model/
        // Introductory audio rate checked 2026-10-12; expires at the end of 2026.
        AzureTranscriptionModels.mai2Streaming: perHour("0.54")
    ]

    private static let prefixRates: [(prefix: String, rate: Decimal)] = [
        ("elevenlabs/", perHour("0.40")),
        ("gladia/", perHour("0.612")),
        ("revai/", rate("0.02")),
        ("azure/", perHour("1.00"))
    ]
}
