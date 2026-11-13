// swiftlint:disable file_length
// ModelCatalog grows with provider releases; its catalogue arrays are the
// single source of truth for model pickers and routing. Split types into
// `ModelCatalogTypes.swift`; keep arrays together to avoid scattering.
import Foundation

public struct ModelCatalog: Sendable { // swiftlint:disable:this type_body_length

    public static let customOptionID = "__model_custom__"

    /// Announced shutdowns are labelled and shut-down entries hidden by
    /// `ModelRetirements` on each read, so a process running across a shutdown
    /// stops offering the model; the normalisers move saved selections.
    public static var liveTranscription: [Option] { ModelRetirements.current(scheduledLiveTranscription) }
    public static var batchTranscription: [Option] { ModelRetirements.current(scheduledBatchTranscription) }

    private static let scheduledLiveTranscription: [Option] = appleLiveTranscriptionOptions + [
        Option(
            id: "apple/local/Dictation", displayName: "Apple Dictation",
            description: "Alternative on-device engine that mirrors system dictation.",
            estimatedLatencyMs: 100, latencyTier: .instant),
        Option(
            id: "deepgram/nova-3-streaming", displayName: "Deepgram Nova-3 (Streaming)",
            description: "Real-time WebSocket streaming transcription with interim results.",
            estimatedLatencyMs: 200, latencyTier: .fast),
        Option(
            id: "deepgram/flux-general-en-streaming",
            displayName: "Deepgram Flux (English Streaming)",
            description: "Conversational streaming model with integrated end-of-turn detection.",
            estimatedLatencyMs: 180, latencyTier: .fast),
        Option(
            id: "deepgram/flux-general-multi-streaming",
            displayName: "Deepgram Flux (Multilingual Streaming)",
            description: "Flux conversational streaming with multilingual detection and language hints.",
            estimatedLatencyMs: 220, latencyTier: .fast),
        Option(
            id: "cartesia/ink-2-streaming",
            displayName: "Cartesia Ink-2 (Streaming)",
            description: "Real-time STT in English, French, Hindi, Japanese and Spanish, "
                + "with built-in turn detection and structured-data accuracy.",
            estimatedLatencyMs: 180, latencyTier: .fast),
        Option(
            id: "gladia/solaria-1-streaming",
            displayName: "Gladia Solaria-1 (Streaming)",
            description: "Real-time multilingual STT with automatic language detection and partial transcripts.",
            estimatedLatencyMs: 220, latencyTier: .fast),
        Option(
            id: GeminiTranscribeModels.liveCatalogID,
            displayName: "Gemini 3.5 Transcribe Live",
            description: "Google's real-time Gemini Live API transcription across 85+ languages with "
                + "automatic language detection. Opt-in; never a default or fallback.",
            estimatedLatencyMs: 200, latencyTier: .fast),
        Option(
            id: "modulate/velma-2-stt-streaming", displayName: "Modulate Velma-2 (Streaming)",
            description: "Real-time multilingual WebSocket transcription with diarization and signal detection.",
            estimatedLatencyMs: 220, latencyTier: .fast),
        Option(
            id: AssemblyAIModels.universal36ProStreamingID,
            displayName: "AssemblyAI Universal-3.6 Pro (Streaming)",
            description: "AssemblyAI's flagship real-time model with native code switching across 32 languages.",
            estimatedLatencyMs: 250, latencyTier: .fast),
        Option(
            id: "soniox/stt-rt-v6-streaming",
            displayName: "Soniox Real-time v6 (Streaming)",
            description: "Soniox v6 real-time WebSocket STT with speaker diarization, stronger "
                + "multilingual recognition and faster dictation across 60+ languages.",
            estimatedLatencyMs: 220, latencyTier: .fast),
        Option(
            id: MetaMuseVoiceTranscribe.liveCatalogID,
            displayName: "Meta Muse Voice Transcribe (Streaming)",
            description: "Meta Model API realtime speech-to-text with partial transcripts, "
                + "model-detected utterance boundaries, and language and vocabulary biasing.",
            estimatedLatencyMs: 200,
            latencyTier: .fast,
            tags: [.fast, .leading]),
        Option(
            id: "speechmatics/enhanced-streaming",
            displayName: "Speechmatics Enhanced (Streaming)",
            description: "Speechmatics realtime WebSocket transcription with partial and final results.",
            estimatedLatencyMs: 220, latencyTier: .fast),
        Option(
            id: elevenLabsScribeV3LiveID,
            displayName: "ElevenLabs Scribe v3 Live (Streaming)",
            description: "ElevenLabs' most accurate real-time Scribe model, on the same WebSocket as "
                + "Scribe v2. Reuses your ElevenLabs API key with speech-to-text (Scribe) access.",
            estimatedLatencyMs: 200, latencyTier: .fast),
        Option(
            id: "elevenlabs/scribe-v2-streaming",
            displayName: "ElevenLabs Scribe v2 (Streaming)",
            description: "ElevenLabs Scribe v2 real-time WebSocket transcription. Reuses your "
                + "ElevenLabs API key — the key must have speech-to-text (Scribe) access.",
            estimatedLatencyMs: 200, latencyTier: .fast),
        Option(
            id: XAIVoiceModels.voice3CatalogID,
            displayName: "Grok Voice 3.0 (Streaming)",
            description: "xAI's flagship realtime voice model, used in transcription-only mode "
                + "with cumulative live captions and no assistant response.",
            estimatedLatencyMs: 200,
            latencyTier: .fast,
            tags: [.fast, .leading]),
        Option(
            id: XAISpeechToText.liveCatalogID,
            displayName: XAISpeechToText.displayName + " (Streaming)",
            description: "xAI's dedicated realtime speech-to-text endpoint: interim captions, "
                + "chunk finals as speech locks, and one authoritative transcript at the end of "
                + "the stream. Reuses your xAI API key.",
            estimatedLatencyMs: 200,
            latencyTier: .fast,
            tags: [.fast]),
        Option(
            id: RevAIStreaming.liveCatalogID,
            displayName: "Rev.ai Reverb (Streaming)",
            description: "Rev.ai's streaming speech-to-text on the Reverb model, with rolling "
                + "partial hypotheses and per-segment finals. Reuses your Rev.ai access token.",
            estimatedLatencyMs: 300, latencyTier: .fast),
        Option(
            id: MistralVoxtral3.realtimeID,
            displayName: "Mistral Voxtral Realtime 3 (Streaming, Preview)",
            description: "Voxtral 3 public-preview live transcription with automatic language detection. "
                + "Uses your Mistral API key and the app's 480 ms streaming delay.",
            estimatedLatencyMs: 480, latencyTier: .fast),
        Option(
            id: MistralVoxtralRealtime.liveCatalogID,
            displayName: "Mistral Voxtral Realtime (Streaming)",
            description: "Mistral's natively streaming Voxtral model across 13 languages, with "
                + "automatic language detection and one authoritative transcript at the end of "
                + "the stream. Reuses your Mistral API key.",
            estimatedLatencyMs: 480, latencyTier: .fast),
        Option(
            id: OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID,
            displayName: "OpenAI GPT Live Transcribe (Streaming)",
            description: "OpenAI's recommended low-latency speech-to-text model with live transcript "
                + "deltas and multilingual context hints. Reuses your OpenAI API key.",
            latencyTier: .fast,
            tags: [.fast, .leading]),
        Option(
            id: "openai/gpt-realtime-whisper-streaming",
            displayName: "OpenAI GPT Realtime Whisper (Streaming)",
            description: "OpenAI's gpt-realtime-whisper — low-latency streaming transcription with "
                + "built-in noise reduction. Reuses your OpenAI API key.",
            estimatedLatencyMs: 250, latencyTier: .fast),
        Option(
            id: "openai/gpt-4o-mini-transcribe-streaming",
            displayName: "OpenAI GPT-4o mini Transcribe (Streaming)",
            description: "OpenAI's gpt-4o-mini-transcribe over the Realtime API — fast, low-cost "
                + "streaming transcription with keyterm prompt support. Reuses your OpenAI API key.",
            estimatedLatencyMs: 220, latencyTier: .fast),
        Option(
            id: "openai/gpt-4o-transcribe-streaming",
            displayName: "OpenAI GPT-4o Transcribe (Streaming)",
            description: "OpenAI's flagship gpt-4o-transcribe over the Realtime API — higher "
                + "accuracy on noisy or accented audio with keyterm prompt support. Reuses your "
                + "OpenAI API key.",
            estimatedLatencyMs: 280, latencyTier: .fast)
    ] + AzureTranscriptionModels.liveOptions + AlibabaSpeechModels.liveOptions
        + [FileSpeechProvider.reson8LiveOption]

    /// Every batch entry including shut-down ones, for routing a saved selection
    /// to the client that reports `ModelRetiredError`. Pickers use `batchTranscription`.
    static let scheduledBatchTranscription: [Option] =
        appleBatchTranscriptionOptions + AlibabaSpeechModels.batchOptions + [
        Option(
            id: BatchTranscriptionModelIdentifiers.cartesiaInkWhisper, displayName: "Cartesia Ink Whisper (Batch)",
            description: "Multilingual file transcription. Choose the recording language; Automatic uses English.",
            estimatedLatencyMs: nil, latencyTier: .medium),
        Option(
            id: BatchTranscriptionModelIdentifiers.gladiaSolaria, displayName: "Gladia Solaria-1 (Batch)",
            description: "Multilingual file transcription with per-utterance timings. "
                + "Automatic detects the language and allows code switching.",
            estimatedLatencyMs: nil, latencyTier: .medium),
        Option(
            id: BatchTranscriptionModelIdentifiers.speechmaticsEnhanced, displayName: "Speechmatics Enhanced (Batch)",
            description: "Speechmatics' higher-accuracy file transcription tier, with word timings "
                + "and automatic language identification.",
            estimatedLatencyMs: nil, latencyTier: .medium),
        Option(
            id: BatchTranscriptionModelIdentifiers.speechmaticsStandard, displayName: "Speechmatics Standard (Batch)",
            description: "Speechmatics' faster, lower-cost file transcription tier.",
            estimatedLatencyMs: nil, latencyTier: .fast),
        // Dedicated transcription providers (OpenAI, Rev.ai, etc.)
        Option(
            id: OpenAITranscriptionModels.gptTranscribeCatalogID,
            displayName: "GPT Transcribe (OpenAI)",
            description: "OpenAI's recommended high-accuracy model for recorded speech, with multilingual "
                + "and domain-context support.",
            latencyTier: .fast,
            tags: [.quality, .leading]),
        Option(
            id: "openai/whisper-1", displayName: "Whisper (OpenAI)",
            description: "OpenAI's speech recognition model. Fast and accurate.",
            estimatedLatencyMs: 800, latencyTier: .fast),
        Option(
            id: "openai/gpt-4o-mini-transcribe", displayName: "GPT-4o mini Transcribe (OpenAI)",
            description: "OpenAI's fast, low-cost transcription model. Improved accuracy vs Whisper-1.",
            estimatedLatencyMs: 700, latencyTier: .fast),
        Option(
            id: "openai/gpt-4o-transcribe", displayName: "GPT-4o Transcribe (OpenAI)",
            description: "OpenAI's flagship transcription model with strong accuracy on noisy, accented audio.",
            estimatedLatencyMs: 900, latencyTier: .fast),
        Option(
            id: "openai/gpt-4o-transcribe-diarize",
            displayName: "GPT-4o Transcribe Diarize (OpenAI)",
            description: "OpenAI's speaker-aware GPT-4o transcription model with diarized JSON segments.",
            estimatedLatencyMs: 1100, latencyTier: .medium),
        Option(
            id: "groq/whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo (Groq)",
            description: "Groq-hosted Whisper Large v3 Turbo. Fast, low-cost OpenAI-compatible batch transcription.",
            estimatedLatencyMs: 500, latencyTier: .fast),
        Option(
            id: MistralVoxtral3.miniBatchID,
            displayName: "Voxtral Mini Transcribe 3 (Mistral, Preview)",
            description: "Voxtral 3 public-preview file transcription with multilingual audio and vocabulary hints.",
            latencyTier: .fast),
        Option(
            id: MistralVoxtral3.smallBatchID,
            displayName: "Voxtral Small Transcribe 3 (Mistral, Preview)",
            description: "Mistral's larger Voxtral 3 public-preview model for higher-quality file transcription.",
            latencyTier: .medium),
        Option(
            id: "mistral/voxtral-mini-latest",
            displayName: "Voxtral Mini Transcribe 2 (Mistral)",
            description: "Mistral's latest Voxtral Mini batch transcription alias for long-form multilingual audio.",
            estimatedLatencyMs: 900, latencyTier: .fast),
        Option(
            id: MetaMuseVoiceTranscribe.batchCatalogID,
            displayName: "Meta Muse Voice Transcribe",
            description: "Meta Model API file transcription with turn-level timestamps, "
                + "language biasing, and vocabulary biasing. Recordings are converted to supported PCM WAV.",
            estimatedLatencyMs: 800,
            latencyTier: .fast,
            tags: [.fast, .leading]),
        Option(
            id: "soniox/stt-async-v6",
            displayName: "Soniox Async v6",
            description: "Soniox v6 asynchronous batch STT with speaker diarization and language identification.",
            estimatedLatencyMs: 1200, latencyTier: .medium),
        Option(
            id: GeminiTranscribeModels.batchCatalogID,
            displayName: "Gemini 3.5 Transcribe (Google)",
            description: "Google's Gemini Interactions API for recorded audio, with word-level "
                + "timestamps and speaker attribution. Opt-in; never a default.",
            estimatedLatencyMs: 900, latencyTier: .fast),
        Option(
            id: XAISpeechToText.batchCatalogID,
            displayName: XAISpeechToText.displayName,
            description: "xAI's dedicated file transcription endpoint, with word timings, "
                + "keyterm biasing and inverse text normalisation when a language is chosen.",
            estimatedLatencyMs: 700, latencyTier: .fast),
        Option(
            id: "revai/default", displayName: "Rev.ai",
            description: "Rev.ai's speech recognition. High accuracy with speaker identification.",
            estimatedLatencyMs: 1500, latencyTier: .medium),

        // OpenRouter multimodal models
        Option(
            id: "thinkingmachines/inkling", displayName: "Inkling (OpenRouter)",
            description: "Thinking Machines' hosted multimodal model with audio input. "
                + "Up to 20 minutes, prepared as 16 kHz WAV. Chat completions, not live speech.",
            latencyTier: .medium, tags: [.quality]),
        Option(
            id: "thinkingmachines/inkling-small", displayName: "Inkling Small (OpenRouter)",
            description: "Smaller hosted Inkling model for recorded audio, up to 20 minutes as 16 kHz WAV.",
            latencyTier: .medium, tags: [.cheap]),
        Option(
            id: "google/gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro Preview (OpenRouter)",
            description: "Gemini Pro audio understanding for recorded-audio transcription. "
                + "Uses OpenRouter, not Google's dedicated Transcribe API.",
            latencyTier: .medium, tags: [.quality]),
        Option(
            id: "mistralai/voxtral-small-24b-2507", displayName: "Voxtral Small 24B (OpenRouter)",
            description: "Mistral's audio-capable Voxtral Small for recorded-audio transcription through "
                + "OpenRouter chat completions, not the direct Mistral transcription endpoint.",
            latencyTier: .medium, tags: [.quality]),
        Option(
            id: "google/gemini-3.8-flash", displayName: "Gemini 3.8 Flash (OpenRouter)",
            description: "Current Gemini Flash generation with audio input for recorded-audio transcription.",
            latencyTier: .fast),
        Option(
            id: "google/gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash Lite (OpenRouter)",
            description: "Current Gemini Flash Lite generation with audio input. Opt-in; keeps saved models unchanged.",
            latencyTier: .fast, tags: [.cheap]),
        Option(
            id: "google/gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash Lite (OpenRouter)",
            description: "Budget-friendly Gemini multimodal option. Preserved for existing selections.",
            estimatedLatencyMs: 400, latencyTier: .fast),
        Option(
            id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash (OpenRouter)",
            description: "Fast multimodal model with strong shorthand transcription.",
            estimatedLatencyMs: 600, latencyTier: .fast),
        Option(
            id: "openai/gpt-audio",
            displayName: "GPT Audio (OpenRouter)",
            description: "OpenAI's available audio-chat model on OpenRouter. "
                + "Recorded-audio transcription through chat completions, not OpenAI's transcription endpoint.",
            estimatedLatencyMs: 2000, latencyTier: .medium),
        Option(
            id: "deepgram/nova-3", displayName: "Deepgram Nova-3",
            description: "Third-party streaming/batch model.",
            estimatedLatencyMs: 500, latencyTier: .fast),
        Option(
            id: "deepgram/nova", displayName: "Deepgram Nova",
            description: "Deepgram's previous generation model. Fast and reliable.",
            latencyTier: .fast),
        Option(
            id: "deepgram/enhanced", displayName: "Deepgram Enhanced",
            description: "Optimized for specific use cases like phone calls and meetings.",
            latencyTier: .medium),
        Option(
            id: "deepgram/base", displayName: "Deepgram Base",
            description: "Deepgram's base model. Good balance of speed and accuracy.",
            latencyTier: .medium),
        Option(
            id: "modulate/velma-2-stt-batch", displayName: "Modulate Velma-2 Batch",
            description: "Multilingual batch transcription with diarization, emotion, accent, and PII/PHI options.",
            estimatedLatencyMs: 1200, latencyTier: .medium),
        Option(
            id: "modulate/velma-2-stt-batch-english-vfast",
            displayName: "Modulate Velma-2 Batch (English Fast)",
            description: "High-throughput English batch transcription with automatic punctuation and capitalization.",
            estimatedLatencyMs: 700, latencyTier: .fast),
        Option(
            id: AssemblyAIModels.universal35ProBatchID,
            displayName: "AssemblyAI Universal-3.5 Pro",
            description: "AssemblyAI's fastest, highest-accuracy batch model with 18-language code switching.",
            estimatedLatencyMs: 1500, latencyTier: .medium),
        Option(
            id: AssemblyAIModels.universal2BatchID, displayName: "AssemblyAI Universal-2",
            description: "Fast and reliable batch transcription from AssemblyAI.",
            estimatedLatencyMs: 1200, latencyTier: .medium),
        Option(
            id: elevenLabsScribeV3BatchID, displayName: "ElevenLabs Scribe v3",
            description: "ElevenLabs' most accurate Scribe model for recorded audio, across 90+ languages "
                + "with word-level timestamps. Same API and price as Scribe v2.",
            estimatedLatencyMs: 800, latencyTier: .fast),
        Option(
            id: elevenLabsScribeV2BatchID, displayName: "ElevenLabs Scribe v2",
            description: "ElevenLabs Scribe v2: high-accuracy speech-to-text across 90+ languages "
                + "with word-level timestamps.",
            estimatedLatencyMs: 800, latencyTier: .fast),
        Option(
            id: elevenLabsScribeV2MedicalBatchID, displayName: "ElevenLabs Scribe v2 Medical",
            description: "Scribe v2 fine-tuned for clinical audio: fewer errors on medical terminology, "
                + "with the same languages, pricing and word-level timestamps as Scribe v2.",
            estimatedLatencyMs: 800, latencyTier: .fast)
    ] + AzureTranscriptionModels.batchOptions + FileSpeechProvider.batchOptions

    /// ElevenLabs' successor to Scribe v2 (models page, checked 2026-11-11):
    /// same `POST /v1/speech-to-text` request with `model_id=scribe_v3`.
    /// Scribe v2 remains available, so saved v2 selections are not moved.
    public static let elevenLabsScribeV3BatchID = "elevenlabs/scribe_v3"

    /// Scribe v3 Live: the realtime WebSocket with `model_id=scribe_v3_live`.
    public static let elevenLabsScribeV3LiveID = "elevenlabs/scribe-v3-live-streaming"

    /// Current ElevenLabs batch speech-to-text model. ElevenLabs removed
    /// `scribe_v1` (and its experimental variant) on 2026-07-09.
    public static let elevenLabsScribeV2BatchID = "elevenlabs/scribe_v2"

    /// Scribe v2 specialised for medical and clinical audio (GA 2026-09-11).
    /// Same Create transcript API and per-hour rate as Scribe v2.
    public static let elevenLabsScribeV2MedicalBatchID = "elevenlabs/scribe_v2_medical"

    /// Retired ElevenLabs batch identifiers that must be migrated to Scribe v2
    /// when they are read back out of persisted settings.
    static let legacyElevenLabsBatchIDs: Set<String> = [
        "elevenlabs/scribe_v1",
        "elevenlabs/scribe_v1_experimental"
    ]

    // Retired transcription identifiers are defined once, here, and read by
    // both normalisers, so no host keeps its own list or resets a provider by
    // prefix. Only identifiers that once shipped and were then replaced belong
    // here; current entries and custom models are never listed.

    /// Retired batch identifiers and the current entry each one now selects.
    static let batchTranscriptionSuccessors: [String: String] = Dictionary(
        AssemblyAIModels.legacyUniversal3BatchIDs.map { ($0, AssemblyAIModels.universal35ProBatchID) }
            + legacyElevenLabsBatchIDs.map { ($0, elevenLabsScribeV2BatchID) }
            + [("openai/gpt-4o-audio-preview-2024-12-17", "openai/gpt-audio"),
               // OpenRouter removed the free Inkling routes (HTTP 404, #1655); the
               // paid routes run the same model through the same key, now token-billed.
               ("thinkingmachines/inkling:free", "thinkingmachines/inkling"),
               ("thinkingmachines/inkling-small:free", "thinkingmachines/inkling-small"),
               ("soniox/stt-async-v3", "soniox/stt-async-v6"),
               ("soniox/stt-async-v4", "soniox/stt-async-v6"),
               ("soniox/stt-async-v5", "soniox/stt-async-v6")],
        uniquingKeysWith: { first, _ in first }
    )

    /// Retired live identifiers and the current entry each one now selects.
    /// Nova-2 is Deepgram's only retired stream (the Nova-3 upgrade in #64):
    /// Flux and any later `deepgram/` entry are current, so they never appear here.
    static let liveTranscriptionSuccessors: [String: String] = Dictionary(
        AssemblyAIModels.legacyUniversal3StreamingIDs.map { ($0, AssemblyAIModels.universal36ProStreamingID) }
            + [("deepgram/nova-2-streaming", "deepgram/nova-3-streaming"),
               ("soniox/stt-rt-v3-streaming", "soniox/stt-rt-v6-streaming"),
               ("soniox/stt-rt-v4-streaming", "soniox/stt-rt-v6-streaming"),
               ("soniox/stt-rt-v5-streaming", "soniox/stt-rt-v6-streaming"),
               (XAIVoiceModels.thinkFast2CatalogID, XAIVoiceModels.voice3CatalogID)],
        uniquingKeysWith: { first, _ in first }
    )

    public static let defaultBatchTranscriptionModel = "google/gemini-3.1-flash-lite"

    /// Batch catalogue options owned by a provider, matched by the `provider/`
    /// prefix on the model identifier. Transcription providers derive their
    /// `supportedModels()` from these helpers so the catalogue stays the single
    /// source of truth for both the model pickers and provider routing.
    ///
    /// Note: OpenAI cannot use a prefix match because `openai/`-prefixed
    /// OpenRouter models share the batch catalogue; it filters by
    /// `OpenAITranscriptionModels.directBatchModelIDs` instead.
    public static func batchTranscriptionOptions(forProvider providerID: String) -> [Option] {
        options(in: batchTranscription, forProvider: providerID)
    }

    /// Live catalogue options owned by a provider. See
    /// `batchTranscriptionOptions(forProvider:)`.
    public static func liveTranscriptionOptions(forProvider providerID: String) -> [Option] {
        options(in: liveTranscription, forProvider: providerID)
    }

    private static func options(in options: [Option], forProvider providerID: String) -> [Option] {
        let prefix = providerID.lowercased() + "/"
        return options.filter { $0.id.lowercased().hasPrefix(prefix) }
    }

    private static let appleLiveTranscriptionOptions: [Option] = {
        if AppleLocalModels.supportsSpeechTranscriber {
            return [Option(
                id: AppleLocalModels.speechTranscriberModelID,
                displayName: "Apple SpeechTranscriber (On-device)",
                description: "Apple's latest private on-device model for fast, accurate live transcription.",
                estimatedLatencyMs: 50,
                latencyTier: .instant,
                tags: [.fast, .privacy]
            )]
        }
        if AppleLocalModels.supportsDictationTranscriber {
            return [Option(
                id: AppleLocalModels.dictationTranscriberModelID,
                displayName: "Apple DictationTranscriber (On-device)",
                description: "Apple's on-device dictation model via SpeechAnalyzer; "
                    + "no Apple Intelligence required.",
                estimatedLatencyMs: 50,
                latencyTier: .instant,
                tags: [.fast, .privacy]
            )]
        }
        return [Option(
            id: AppleLocalModels.legacySpeechModelID,
            displayName: "Apple Speech (On-device)",
            description: "Uses the built-in Speech framework for immediate on-device transcripts.",
            estimatedLatencyMs: 50,
            latencyTier: .instant,
            tags: [.fast, .privacy]
        )]
    }()

    private static let appleBatchTranscriptionOptions: [Option] = {
        if AppleLocalModels.supportsSpeechTranscriber {
            return [Option(
                id: AppleLocalModels.speechTranscriberModelID,
                displayName: "Apple SpeechTranscriber (On-device)",
                description: "Transcribes recorded audio locally with Apple's latest long-form speech model.",
                estimatedLatencyMs: 250,
                latencyTier: .instant,
                tags: [.fast, .privacy]
            )]
        }
        if AppleLocalModels.supportsDictationTranscriber {
            return [Option(
                id: AppleLocalModels.dictationTranscriberModelID,
                displayName: "Apple DictationTranscriber (On-device)",
                description: "Transcribes recorded audio locally with Apple's on-device dictation model.",
                estimatedLatencyMs: 250,
                latencyTier: .instant,
                tags: [.fast, .privacy]
            )]
        }
        return []
    }()

    private static let retiredBatchTranscriptionModels: Set<String> = [
        // Google retired Gemini 2.0 Flash; OpenRouter selections move to the default.
        "google/gemini-2.0-flash-001",
        "google/gemini-2.0-flash-lite-001",
        "openrouter/whisper-large-v3",
        "openrouter/whisper-medium",
        "openrouter/whisper-small"
    ]

    /// Keeps catalogue defaults and retired-model migration identical on Mac and iPhone.
    /// Unknown identifiers remain valid because the Mac supports custom OpenRouter batch models.
    public static func normalizedBatchTranscriptionModel(_ identifier: String?) -> String {
        normalizedBatchTranscriptionModel(identifier, at: Date())
    }

    public static func normalizedBatchTranscriptionModel(_ identifier: String?, at date: Date) -> String {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let successor = batchTranscriptionSuccessors[trimmed]
            ?? ModelRetirements.successor(for: trimmed, mode: .batch, at: date) {
            return successor
        }
        if trimmed == AppleLocalModels.speechTranscriberModelID,
           !AppleLocalModels.supportsSpeechTranscriber {
            return AppleLocalModels.supportsDictationTranscriber
                ? AppleLocalModels.dictationTranscriberModelID
                : defaultBatchTranscriptionModel
        }
        if trimmed == AppleLocalModels.dictationTranscriberModelID,
           !AppleLocalModels.supportsDictationTranscriber {
            return defaultBatchTranscriptionModel
        }
        guard !trimmed.isEmpty, !retiredBatchTranscriptionModels.contains(trimmed) else {
            return defaultBatchTranscriptionModel
        }
        return trimmed
    }

    // Curated, static set for transcript cleanup with pricing + tags: on-device, then
    // native provider routes, then OpenRouter routes.
    // Pricing is based on OpenRouter's /api/v1/models at time of writing.
    // Announced shutdowns are labelled and shut-down entries hidden on each read.
    public static var postProcessing: [Option] { ModelRetirements.current(scheduledPostProcessing) }

    private static let scheduledPostProcessing: [Option] = applePostProcessingOptions + [
        Option(
            id: "local/post-processing/rules",
            displayName: "Local Cleanup (Offline)",
            description: "Runs entirely on this Mac. Applies safe transcript cleanup without cloud LLMs.",
            estimatedLatencyMs: 50,
            latencyTier: .instant,
            tags: [.fast, .cheap, .privacy]
        )
    ] + NativeTextModels.postProcessing + [
        // OpenRouter routes. Unprefixed IDs are OpenRouter slugs; native routes use `native/`.
        // IDs and base rates verified 12 November 2026 against OpenRouter's models API and
        // the providers' pricing pages; see Docs/cleanup-model-upgrades-2026-11.md. The list
        // keeps one entry per price/quality tier: a model that a newer, cheaper model from the
        // same provider matches is removed and migrated by `CleanupModelRemovals`.
        // New entries carry no measured cleanup latency; Option's default tier applies.
        Option(
            id: "openai/gpt-6-luna",
            displayName: "GPT-6 Luna",
            description: "Cost-efficient GPT-6 option via OpenRouter. "
                + "Base token pricing shown; long-context rates may be higher.",
            tags: [.cheap],
            pricing: Pricing(promptPerMTokens: 0.10, completionPerMTokens: 0.50),
            contextLength: 1_050_000
        ),
        Option(
            id: "openai/gpt-6.1-terra",
            displayName: "GPT-6.1 Terra",
            description: "Balanced GPT-6.1 quality and cost via OpenRouter. "
                + "Base token pricing shown; long-context rates may be higher.",
            tags: [.quality],
            pricing: Pricing(promptPerMTokens: 1.0, completionPerMTokens: 5.0),
            contextLength: 1_050_000
        ),
        Option(
            id: "openai/gpt-6.1-sol",
            displayName: "GPT-6.1 Sol",
            description: "OpenAI's middle GPT-6 tier via OpenRouter, priced below Astra. "
                + "Base token pricing shown; long-context rates may be higher.",
            pricing: Pricing(promptPerMTokens: 2.0, completionPerMTokens: 10.0),
            contextLength: 1_050_000
        ),
        Option(
            id: "openai/gpt-6-astra",
            displayName: "GPT-6 Astra",
            description: "OpenAI's flagship GPT-6 option via OpenRouter, at a higher token cost. "
                + "Base token pricing shown; long-context rates may be higher.",
            tags: [.leading],
            pricing: Pricing(promptPerMTokens: 10.0, completionPerMTokens: 50.0),
            contextLength: 1_050_000
        ),
        Option(
            id: "google/gemini-3.1-flash-lite",
            displayName: "Gemini 3.1 Flash Lite",
            description: "Latest Gemini Flash Lite generation with low cost and a long context window.",
            estimatedLatencyMs: 400,
            latencyTier: .fast,
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.25, completionPerMTokens: 1.5),
            contextLength: 1_048_576
        ),
        Option(
            id: "google/gemini-3.5-flash-lite",
            displayName: "Gemini 3.5 Flash Lite",
            description: "Newest Gemini Flash Lite; Google's replacement for Gemini 2.5 Flash.",
            tags: [.fast],
            pricing: Pricing(promptPerMTokens: 0.30, completionPerMTokens: 2.5),
            contextLength: 1_048_576
        ),
        Option(
            id: "google/gemini-2.5-flash-lite",
            displayName: "Gemini 2.5 Flash Lite",
            description: "Very fast and inexpensive for everyday cleanup.",
            estimatedLatencyMs: 450,
            latencyTier: .fast,
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.1, completionPerMTokens: 0.4),
            contextLength: 1_048_576
        ),
        Option(
            id: "qwen/qwen3.8-flash",
            displayName: "Qwen3.8 Flash",
            description: "Newest fast Qwen model with low-cost long-context cleanup.",
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.15, completionPerMTokens: 0.47),
            contextLength: 1_000_000
        ),
        Option(
            id: "mistralai/mistral-small-2603",
            displayName: "Mistral Small 4",
            description: "Newest Mistral Small generation; very inexpensive for simple formatting.",
            estimatedLatencyMs: 450,
            latencyTier: .fast,
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.15, completionPerMTokens: 0.6),
            contextLength: 262_144
        ),
        Option(
            id: "anthropic/claude-haiku-5.5",
            displayName: "Claude Haiku 5.5",
            description: "Anthropic's fastest, lowest-cost Claude via OpenRouter.",
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.10, completionPerMTokens: 0.50),
            contextLength: 1_000_000
        ),
        Option(
            id: "anthropic/claude-sonnet-5.5",
            displayName: "Claude Sonnet 5.5",
            description: "Anthropic's newest Sonnet via OpenRouter, for structure- and tone-preserving cleanup.",
            tags: [.quality, .leading],
            pricing: Pricing(promptPerMTokens: 2.0, completionPerMTokens: 10.0),
            contextLength: 1_000_000
        )
    ]

    public static let localTranscription: [LocalTranscriptionModel] = [
        LocalTranscriptionModel(
            id: "local/whisperkit/tiny",
            displayName: "WhisperKit Tiny",
            modelName: "tiny",
            engine: .whisperKit,
            approximateSizeMB: 75,
            description: "Small downloadable Core ML Whisper model for fast batch or live transcription testing.",
            tags: [.fast, .cheap],
            supportsLiveStreaming: true
        ),
        LocalTranscriptionModel(
            id: "local/whisperkit/base",
            displayName: "WhisperKit Base",
            modelName: "base",
            engine: .whisperKit,
            approximateSizeMB: 145,
            description: "Balanced downloaded Whisper model for private batch or live transcription.",
            tags: [.fast],
            supportsLiveStreaming: true
        ),
        LocalTranscriptionModel(
            id: "local/whisperkit/small",
            displayName: "WhisperKit Small",
            modelName: "small",
            engine: .whisperKit,
            approximateSizeMB: 465,
            description: "Higher quality local Whisper model for batch and live transcription on Apple silicon.",
            tags: [.quality],
            supportsLiveStreaming: true
        ),
        LocalTranscriptionModel(
            id: "local/whisperkit/large-v3-turbo",
            displayName: "WhisperKit Large v3 Turbo",
            modelName: "openai_whisper-large-v3-v20240930_turbo_632MB",
            engine: .whisperKit,
            approximateSizeMB: 632,
            description: "Whisper Large v3 Turbo — near-Large quality with ≈4× real-time speed on "
                + "Apple silicon. Recommended for high-accuracy batch or live transcription.",
            tags: [.quality, .fast, .leading],
            supportsLiveStreaming: true
        ),
        LocalTranscriptionModel(
            id: "local/whisperkit/distil-large-v3",
            displayName: "WhisperKit Distil-Large v3",
            modelName: "distil-whisper_distil-large-v3_594MB",
            engine: .whisperKit,
            approximateSizeMB: 594,
            description: "Distilled Whisper Large v3 — English-optimised, faster and lighter than "
                + "the full Large model with minimal accuracy loss.",
            tags: [.fast, .quality],
            supportsLiveStreaming: true
        ),
        LocalTranscriptionModel(
            id: "local/whisperkit/distil-large-v3-turbo",
            displayName: "WhisperKit Distil-Large v3 Turbo",
            modelName: "distil-whisper_distil-large-v3_turbo_600MB",
            engine: .whisperKit,
            approximateSizeMB: 600,
            description: "Distilled, turbo-optimised Whisper Large v3 — fastest high-quality "
                + "English-only batch or live option on Apple silicon.",
            tags: [.fast, .quality],
            supportsLiveStreaming: true
        )
    ] + [PhononLocalModels.phonon2]

    public static let localTranscriptionOptions: [Option] = localTranscription.map(\.option)

    /// Cloud cleanup choices supported on every platform. Platform-specific
    /// local cleanup engines remain in `postProcessing` for macOS.
    /// Computed so a running process drops models on their shutdown day.
    public static var cloudPostProcessing: [Option] { postProcessing.filter {
        !$0.id.hasPrefix("local/post-processing/") && $0.id != AppleLocalModels.foundationModelID
    } }

    private static let applePostProcessingOptions: [Option] = {
        guard AppleLocalModels.supportsFoundationModels else { return [] }
        return [Option(
            id: AppleLocalModels.foundationModelID,
            displayName: "Apple Intelligence (On-device)",
            description: "Polishes transcripts privately with Apple's built-in on-device language model.",
            estimatedLatencyMs: 300,
            latencyTier: .fast,
            tags: [.fast, .privacy]
        )]
    }()

    /// Apple speech follows this device's preferred engine and retired streams
    /// follow their successor. Current and custom remote identifiers are kept.
    public static func normalizedLiveTranscriptionModel(_ identifier: String?) -> String {
        normalizedLiveTranscriptionModel(identifier, at: Date())
    }

    public static func normalizedLiveTranscriptionModel(_ identifier: String?, at date: Date) -> String {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if AppleLocalModels.isAppleSpeechModel(trimmed) || trimmed.isEmpty {
            return AppleLocalModels.preferredSpeechModelID
        }
        return liveTranscriptionSuccessors[trimmed]
            ?? ModelRetirements.successor(for: trimmed, mode: .live, at: date)
            ?? trimmed
    }

    /// GPT-6 Luna is cheaper ($0.10/$0.50 per million tokens) and newer than
    /// GPT-5.6 Luna, the previous default; see `CleanupModelRemovals`.
    public static let defaultPostProcessingModel = "openai/gpt-6-luna"

    /// Low-latency cloud text model for latency-sensitive rewrites (live polish,
    /// spoken-response summaries) when the user has not chosen one.
    public static let defaultFastTextModel = "google/gemini-3.1-flash-lite"

    /// The configured post-processing model, or the default when the setting is
    /// empty. Unlike `normalizedPostProcessingModel`, custom identifiers are kept.
    public static func resolvedPostProcessingModel(_ identifier: String?) -> String {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultPostProcessingModel : trimmed
    }

    /// Migrates retired selections while preserving valid catalogue entries
    /// and custom local cleanup models installed by the user.
    public static func normalizedPostProcessingModel(_ identifier: String?) -> String {
        normalizedPostProcessingModel(identifier, at: Date())
    }

    public static func normalizedPostProcessingModel(_ identifier: String?, at date: Date) -> String {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let current = currentPostProcessingModel(trimmed, at: date)
        if current != trimmed { return current }
        if trimmed.hasPrefix("local/post-processing/") || CleanupModelSelection.modelID(from: trimmed) != nil {
            return trimmed
        }
        if scheduledPostProcessing.contains(where: { $0.id == trimmed }) { return trimmed }
        return defaultPostProcessingModel
    }

    public static let allOptions: [Option] =
        liveTranscription + batchTranscription + localTranscriptionOptions + postProcessing

    // O(1) lookup cache keyed on lowercased model ID (first entry wins for cross-category duplicates).
    private static let optionsByID: [String: Option] = Dictionary(
        allOptions.map { ($0.id.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    // existing owned catalogue-matching surface; no behavior change.
    // swiftlint:disable:next function_body_length
    public static func friendlyName(for identifier: String) -> String { // swiftlint:disable:this cyclomatic_complexity
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }

        if let discovered = CleanupModelSelection.modelID(from: trimmed) { return discovered }
        if let exact = optionsByID[trimmed.lowercased()] {
            return exact.displayName
        }
        if let removed = CleanupModelRemovals.removal(for: trimmed) { return removed.displayName }
        if let local = localPostProcessing.first(where: { $0.id.lowercased() == trimmed.lowercased() }) {
            return local.displayName
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix(LocalModelIdentity.postProcessingHuggingFacePrefix) {
            let parts = trimmed
                .dropFirst(LocalModelIdentity.postProcessingHuggingFacePrefix.count)
                .split(separator: "/")
            if parts.count == 3 {
                let filename = String(parts[2])
                let stem = filename.lowercased().hasSuffix("-gguf") ? String(filename.dropLast(5)) : filename
                return LocalPostProcessingModel.importedDisplayName(
                    repoID: "\(parts[0])/\(parts[1])", filename: stem
                )
            }
        }
        if let imported = HuggingFaceWhisperModel.fallbackDisplayName(for: lowercased) { return imported }
        if lowercased.hasPrefix("local/") {
            if lowercased == "local/streaming/fluidaudio/parakeet-realtime-eou-120m" {
                return "Parakeet Realtime EOU 120M"
            }
            if lowercased == ParakeetLocalModels.tdtV3Int8SourceID {
                return ParakeetLocalModels.tdtV3DisplayName
            }
            if lowercased == "local/post-processing/rules" {
                return "Local Cleanup (Offline)"
            }
            if lowercased.hasPrefix("local/post-processing/") {
                return friendlyLocalModelName(
                    from: trimmed,
                    prefixes: [
                        "local/post-processing/huggingface/",
                        "local/post-processing/"
                    ]
                )
            }
            if lowercased.hasPrefix("local/whisperkit/huggingface/") {
                return friendlyLocalModelName(from: trimmed, prefixes: ["local/whisperkit/huggingface/"])
            }
            if lowercased.hasPrefix("local/streaming/huggingface/") {
                return friendlyLocalModelName(from: trimmed, prefixes: ["local/streaming/huggingface/"])
            }
            if let name = localTranscription.first(where: { $0.id.lowercased() == lowercased })?.displayName {
                return name
            }
            return "Downloaded Local Model"
        }
        if lowercased.hasPrefix("apple/local") {
            return "Apple Speech"
        }
        if lowercased.contains("whisper") {
            return "Whisper (\(trimmed))"
        }
        if let lastComponent = trimmed.split(separator: "/").last {
            return String(lastComponent).replacingOccurrences(of: "-", with: " ").capitalized
        }
        return trimmed
    }

    /// User-facing transcription label shared by the iOS recording surfaces.
    public static func transcriptionDisplayName(
        for identifier: String,
        isBatch: Bool
    ) -> String {
        if isBatch { return friendlyName(for: identifier) }
        guard let route = LiveTranscriptionRouting.route(for: identifier) else {
            return "Apple Speech"
        }
        switch route.provider {
        case .apple:
            return "Apple Speech"
        case .deepgram, .elevenlabs:
            return route.provider.displayName
        default:
            return friendlyName(for: identifier)
        }
    }

    private static func friendlyLocalModelName(from identifier: String, prefixes: [String]) -> String {
        var working = identifier
        let lowercased = identifier.lowercased()
        if let prefix = prefixes.first(where: { lowercased.hasPrefix($0) }) {
            working = String(identifier.dropFirst(prefix.count))
        }
        let components = working.split(separator: "/").map(String.init)
        let candidate = components.last ?? working
        return candidate
            .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: #"(?i)\bq([0-9])\s+k\s+([a-z])\b"#,
                with: "Q$1_K_$2",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)\b([0-9]+)mb\b"#, with: "$1 MB", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b([0-9]+)gb\b"#, with: "$1 GB", options: .regularExpression)
            .capitalized
            .replacingOccurrences(of: "Gguf", with: "GGUF")
            .replacingOccurrences(of: " Mb", with: " MB")
            .replacingOccurrences(of: " Gb", with: " GB")
            .replacingOccurrences(of: "Qwen", with: "Qwen")
    }
}
