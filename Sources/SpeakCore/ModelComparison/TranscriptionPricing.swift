import Foundation

/// Published per-minute list prices for speech-to-text models, used to put an
/// estimated cost next to each Compare Models result.
///
/// These are estimates. Providers bill in different units (seconds, hours,
/// audio tokens) and change list prices without notice, so every figure here
/// is the public pay-as-you-go rate converted to US dollars per audio minute,
/// last reviewed on `lastReviewed`. Models without a public per-minute rate
/// (token-billed realtime sessions, private previews) return `nil` and the
/// UI shows no cost rather than a guess. On-device models cost nothing.
public enum TranscriptionPricing {
    /// When the table below was last checked against provider pricing pages.
    public static let lastReviewed = "2026-09"

    /// Estimated US-dollar cost of transcribing `durationSeconds` of audio
    /// with `modelID`, or `nil` when no rate is known.
    public static func estimatedCostUSD(modelID: String, durationSeconds: Double) -> Decimal? {
        guard durationSeconds > 0, let perMinute = pricePerMinuteUSD(modelID: modelID) else { return nil }
        return Decimal(durationSeconds) / 60 * perMinute
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
        // OpenAI: $0.006/min for Whisper and gpt-4o-transcribe, $0.003/min for
        // the mini tier. The realtime transcription sessions are billed on
        // audio input tokens, which the same per-minute figures approximate.
        "openai/whisper-1": rate("0.006"),
        "openai/gpt-4o-transcribe": rate("0.006"),
        "openai/gpt-4o-mini-transcribe": rate("0.003"),
        "openai/gpt-4o-transcribe-streaming": rate("0.006"),
        "openai/gpt-4o-mini-transcribe-streaming": rate("0.003"),
        // Deepgram pay-as-you-go: Nova-3 and Flux $0.0077, Nova $0.0058,
        // Enhanced $0.0165, Base $0.0145 (matches the app's Deepgram cost hook).
        "deepgram/nova-3": rate("0.0077"),
        "deepgram/nova-3-streaming": rate("0.0077"),
        "deepgram/flux-general-en-streaming": rate("0.0077"),
        "deepgram/flux-general-multi-streaming": rate("0.0077"),
        "deepgram/nova": rate("0.0058"),
        "deepgram/enhanced": rate("0.0165"),
        "deepgram/base": rate("0.0145"),
        // Modulate Velma: $0.03/hr batch, $0.025/hr English very-fast,
        // $0.06/hr streaming (matches ModulateTranscriptionProvider).
        "modulate/velma-2-stt-batch": perHour("0.03"),
        "modulate/velma-2-stt-batch-english-vfast": perHour("0.025"),
        "modulate/velma-2-stt-streaming": perHour("0.06"),
        // AssemblyAI: Universal $0.27/hr pre-recorded, $0.15/hr streaming.
        AssemblyAIModels.universal35ProStreamingID: perHour("0.15"),
        // Soniox: $0.10/hr async, $0.12/hr real-time.
        "soniox/stt-async-v5": perHour("0.10"),
        "soniox/stt-rt-v5-streaming": perHour("0.12"),
        // Groq Whisper large-v3-turbo: $0.04 per audio hour.
        "groq/whisper-large-v3-turbo": perHour("0.04"),
        // Mistral Voxtral Mini transcription: $0.001/min.
        "mistral/voxtral-mini-latest": rate("0.001"),
        // Google Gemini audio input: $0.70 per 1M tokens for 2.0 Flash and
        // $0.075 for Flash-Lite, at 32 audio tokens per second.
        "google/gemini-2.0-flash-001": rate("0.00134"),
        "google/gemini-2.0-flash-lite-001": rate("0.00014"),
        // Gladia: $0.612/hr pre-recorded, $0.75/hr real-time.
        "gladia/solaria-1-streaming": perHour("0.75")
    ]

    private static let prefixRates: [(prefix: String, rate: Decimal)] = [
        ("assemblyai/", perHour("0.27")),
        ("elevenlabs/", perHour("0.40")),
        ("gladia/", perHour("0.612")),
        ("revai/", rate("0.02")),
        ("azure/", perHour("1.00"))
    ]
}
