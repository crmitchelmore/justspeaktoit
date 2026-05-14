import Foundation

public enum LatencyTier: String, Codable, CaseIterable, Comparable, Sendable {
    case instant
    case fast
    case medium
    case slow

    public var displayName: String {
        switch self {
        case .instant: return "Instant"
        case .fast: return "Fast"
        case .medium: return "Medium"
        case .slow: return "Slow"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .instant: return 0
        case .fast: return 1
        case .medium: return 2
        case .slow: return 3
        }
    }

    public static func < (lhs: LatencyTier, rhs: LatencyTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

public struct ModelCatalog: Sendable { // swiftlint:disable:this type_body_length
    public enum Tag: String, Codable, CaseIterable, Hashable, Sendable {
        case fast
        case cheap
        case quality
        case leading
        case privacy

        public var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .cheap: return "Cheap"
            case .quality: return "Quality"
            case .leading: return "Leading"
            case .privacy: return "Private"
            }
        }
    }

    public struct Pricing: Hashable, Sendable {
        /// Dollars per 1M input tokens.
        public let promptPerMTokens: Double
        /// Dollars per 1M output tokens.
        public let completionPerMTokens: Double

        public init(promptPerMTokens: Double, completionPerMTokens: Double) {
            self.promptPerMTokens = promptPerMTokens
            self.completionPerMTokens = completionPerMTokens
        }

        public var compactDisplay: String {
            "\(Self.formatDollars(promptPerMTokens))/\(Self.formatDollars(completionPerMTokens))"
        }

        public var displayName: String {
            "\(compactDisplay) / 1M"
        }

        private static func formatDollars(_ value: Double) -> String {
            if value >= 10 { return String(format: "$%.0f", value) }
            if value >= 0.1 { return String(format: "$%.2f", value) }
            if value > 0 { return String(format: "$%.3f", value) }
            return "$0"
        }
    }

    public struct Option: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
        public let description: String?
        public let estimatedLatencyMs: Int?
        public let latencyTier: LatencyTier
        public let tags: [Tag]
        public let pricing: Pricing?
        public let contextLength: Int?

        public init(
            id: String,
            displayName: String,
            description: String? = nil,
            estimatedLatencyMs: Int? = nil,
            latencyTier: LatencyTier = .medium,
            tags: [Tag] = [],
            pricing: Pricing? = nil,
            contextLength: Int? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.description = description
            self.estimatedLatencyMs = estimatedLatencyMs
            self.latencyTier = latencyTier
            self.tags = tags
            self.pricing = pricing
            self.contextLength = contextLength
        }
    }

    public static let customOptionID = "__model_custom__"

    public static let liveTranscription: [Option] = [
        Option(
            id: "apple/local/SFSpeechRecognizer", displayName: "Apple Speech (On-device)",
            description: "Uses the built-in Speech framework for immediate on-device transcripts.",
            estimatedLatencyMs: 50, latencyTier: .instant),
        Option(
            id: "apple/local/Dictation", displayName: "Apple Dictation",
            description: "Alternative on-device engine that mirrors system dictation.",
            estimatedLatencyMs: 100, latencyTier: .instant),
        Option(
            id: "deepgram/nova-3-streaming", displayName: "Deepgram Nova-3 (Streaming)",
            description: "Real-time WebSocket streaming transcription with interim results.",
            estimatedLatencyMs: 200, latencyTier: .fast),
        Option(
            id: "modulate/velma-2-stt-streaming", displayName: "Modulate Velma-2 (Streaming)",
            description: "Real-time multilingual WebSocket transcription with diarization and signal detection.",
            estimatedLatencyMs: 220, latencyTier: .fast),
        Option(
            id: "assemblyai/u3-rt-pro-streaming", displayName: "AssemblyAI Universal-3 Pro (Streaming)",
            description: "AssemblyAI's u3-rt-pro real-time model. Multilingual with high English accuracy.",
            estimatedLatencyMs: 250, latencyTier: .fast),
        Option(
            id: "soniox/stt-rt-preview-streaming",
            displayName: "Soniox Real-time (Preview)",
            description: "Soniox real-time WebSocket STT (stt-rt-preview) with multilingual support and low latency.",
            estimatedLatencyMs: 220, latencyTier: .fast),
        Option(
            id: "elevenlabs/scribe-v2-streaming",
            displayName: "ElevenLabs Scribe v2 (Streaming)",
            description: "ElevenLabs Scribe v2 real-time WebSocket transcription. Reuses your "
                + "ElevenLabs API key — the key must have speech-to-text (Scribe) access.",
            estimatedLatencyMs: 200, latencyTier: .fast),
        Option(
            id: "openai/gpt-realtime-whisper-streaming",
            displayName: "OpenAI Whisper Realtime (Streaming)",
            description: "OpenAI's gpt-realtime-whisper — low-latency streaming transcription with "
                + "built-in noise reduction. Reuses your OpenAI API key.",
            estimatedLatencyMs: 250, latencyTier: .fast)
    ]

    public static let batchTranscription: [Option] = [
        // Dedicated transcription providers (OpenAI, Rev.ai, etc.)
        Option(
            id: "openai/whisper-1", displayName: "Whisper (OpenAI)",
            description: "OpenAI's speech recognition model. Fast and accurate.",
            estimatedLatencyMs: 800, latencyTier: .fast),
        Option(
            id: "revai/default", displayName: "Rev.ai",
            description: "Rev.ai's speech recognition. High accuracy with speaker identification.",
            estimatedLatencyMs: 1500, latencyTier: .medium),

        // OpenRouter multimodal models
        Option(
            id: "google/gemini-2.0-flash-001", displayName: "Gemini 2.0 Flash (OpenRouter)",
            description: "Fast multimodal model with strong shorthand transcription.",
            estimatedLatencyMs: 600, latencyTier: .fast),
        Option(
            id: "google/gemini-2.0-flash-lite-001",
            displayName: "Gemini 2.0 Flash Lite (OpenRouter)",
            description: "Low-latency, budget-friendly multimodal option.",
            estimatedLatencyMs: 400, latencyTier: .fast),
        Option(
            id: "openai/gpt-4o-audio-preview-2024-12-17",
            displayName: "GPT-4o Audio Preview (OpenRouter)",
            description: "Early-access GPT-4o variant optimised for audio understanding.",
            estimatedLatencyMs: 2000, latencyTier: .medium),
        Option(
            id: "deepgram/nova-3", displayName: "Deepgram Nova-3",
            description: "Third-party streaming/batch model.",
            estimatedLatencyMs: 500, latencyTier: .fast),
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
            id: "assemblyai/universal-3-pro", displayName: "AssemblyAI Universal-3 Pro",
            description: "AssemblyAI's most accurate batch transcription model with speaker labels.",
            estimatedLatencyMs: 1500, latencyTier: .medium),
        Option(
            id: "assemblyai/universal-2", displayName: "AssemblyAI Universal-2",
            description: "Fast and reliable batch transcription from AssemblyAI.",
            estimatedLatencyMs: 1200, latencyTier: .medium),
        Option(
            id: "elevenlabs/scribe_v1", displayName: "ElevenLabs Scribe v1",
            description: "ElevenLabs Scribe: high-accuracy speech-to-text with word-level timestamps.",
            estimatedLatencyMs: 800, latencyTier: .fast),
        Option(
            id: "elevenlabs/scribe_v1_experimental",
            displayName: "ElevenLabs Scribe v1 (Experimental)",
            description: "ElevenLabs Scribe experimental model with cutting-edge accuracy improvements.",
            estimatedLatencyMs: 900, latencyTier: .fast)
    ]

    // Curated, static set for transcript cleanup (OpenRouter) with pricing + tags.
    // Pricing is based on OpenRouter's /api/v1/models at time of writing.
    public static let postProcessing: [Option] = [
        Option(
            id: "local/post-processing/rules",
            displayName: "Local Cleanup (Offline)",
            description: "Runs entirely on this Mac. Applies safe transcript cleanup without sending text to a cloud LLM.",
            estimatedLatencyMs: 50,
            latencyTier: .instant,
            tags: [.fast, .cheap, .privacy]
        ),

        // Fast / cheap cleanup
        Option(
            id: "openai/gpt-5.4-nano",
            displayName: "GPT-5.4 Nano",
            description: "Newest ultra-low-cost OpenAI option for quick cleanup.",
            estimatedLatencyMs: 350,
            latencyTier: .fast,
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.20, completionPerMTokens: 1.25),
            contextLength: 400_000
        ),
        Option(
            id: "openai/gpt-5-mini",
            displayName: "GPT-5 Mini",
            description: "Fast and cheap OpenAI reasoning model for reliable transcript cleanup.",
            estimatedLatencyMs: 500,
            latencyTier: .fast,
            tags: [.fast, .cheap, .leading],
            pricing: Pricing(promptPerMTokens: 0.25, completionPerMTokens: 2.0),
            contextLength: 400_000
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
            id: "qwen/qwen3.6-flash",
            displayName: "Qwen3.6 Flash",
            description: "Recent fast Qwen model with low-cost long-context cleanup.",
            estimatedLatencyMs: 400,
            latencyTier: .fast,
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.25, completionPerMTokens: 1.5),
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
            id: "openai/gpt-4o-mini",
            displayName: "GPT-4o mini",
            description: "Fast, reliable transcript cleanup and formatting.",
            estimatedLatencyMs: 500,
            latencyTier: .fast,
            tags: [.fast, .cheap, .leading],
            pricing: Pricing(promptPerMTokens: 0.15, completionPerMTokens: 0.6),
            contextLength: 128_000
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
            id: "qwen/qwen3.6-35b-a3b",
            displayName: "Qwen3.6 35B A3B",
            description: "Tiny-cost recent Qwen model for routine cleanup and formatting.",
            estimatedLatencyMs: 350,
            latencyTier: .fast,
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.15, completionPerMTokens: 1.0),
            contextLength: 262_144
        ),
        Option(
            id: "meta-llama/llama-4-scout",
            displayName: "Llama 4 Scout",
            description: "Cheap long-context cleanup option with good speed.",
            estimatedLatencyMs: 550,
            latencyTier: .fast,
            tags: [.fast, .cheap],
            pricing: Pricing(promptPerMTokens: 0.08, completionPerMTokens: 0.3),
            contextLength: 327_680
        ),

        // Fast / quality cleanup
        Option(
            id: "anthropic/claude-haiku-4.5",
            displayName: "Claude Haiku 4.5",
            description: "Fast, reliable formatting with strong instruction following.",
            estimatedLatencyMs: 900,
            latencyTier: .fast,
            tags: [.fast, .quality],
            pricing: Pricing(promptPerMTokens: 1.0, completionPerMTokens: 5.0),
            contextLength: 200_000
        ),
        Option(
            id: "openai/gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            description: "Recent OpenAI mini model for higher-quality cleanup at moderate cost.",
            estimatedLatencyMs: 650,
            latencyTier: .fast,
            tags: [.fast, .quality],
            pricing: Pricing(promptPerMTokens: 0.75, completionPerMTokens: 4.5),
            contextLength: 400_000
        ),
        Option(
            id: "google/gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            description: "Great speed and quality for large transcript cleanup.",
            estimatedLatencyMs: 650,
            latencyTier: .fast,
            tags: [.fast],
            pricing: Pricing(promptPerMTokens: 0.3, completionPerMTokens: 2.5),
            contextLength: 1_048_576
        ),

        // Leading quality
        Option(
            id: "openai/gpt-5.5",
            displayName: "GPT-5.5",
            description: "Latest OpenAI generation for top-tier transcript cleanup quality.",
            estimatedLatencyMs: 1200,
            latencyTier: .medium,
            tags: [.quality, .leading],
            pricing: Pricing(promptPerMTokens: 5.0, completionPerMTokens: 30.0),
            contextLength: 1_050_000
        ),
        Option(
            id: "anthropic/claude-sonnet-4.6",
            displayName: "Claude Sonnet 4.6",
            description: "Excellent structure + tone preservation.",
            estimatedLatencyMs: 1400,
            latencyTier: .medium,
            tags: [.quality, .leading],
            pricing: Pricing(promptPerMTokens: 3.0, completionPerMTokens: 15.0),
            contextLength: 1_000_000
        ),
        Option(
            id: "openai/gpt-5.4",
            displayName: "GPT-5.4",
            description: "Top-tier cleanup quality with low-latency responses.",
            estimatedLatencyMs: 900,
            latencyTier: .fast,
            tags: [.fast, .quality, .leading],
            pricing: Pricing(promptPerMTokens: 2.5, completionPerMTokens: 15.0),
            contextLength: 1_050_000
        )
    ]

    public static let localTranscription: [LocalTranscriptionModel] = [
        LocalTranscriptionModel(
            id: "local/whisperkit/tiny",
            displayName: "WhisperKit Tiny",
            modelName: "tiny",
            engine: "whisperkit",
            approximateSizeMB: 75,
            description: "Small downloadable Core ML Whisper model for fast offline transcription testing.",
            tags: [.fast, .cheap]
        ),
        LocalTranscriptionModel(
            id: "local/whisperkit/base",
            displayName: "WhisperKit Base",
            modelName: "base",
            engine: "whisperkit",
            approximateSizeMB: 145,
            description: "Balanced downloaded Whisper model for private offline transcription.",
            tags: [.fast]
        ),
        LocalTranscriptionModel(
            id: "local/whisperkit/small",
            displayName: "WhisperKit Small",
            modelName: "small",
            engine: "whisperkit",
            approximateSizeMB: 465,
            description: "Higher quality local Whisper model for longer recordings on Apple silicon.",
            tags: [.quality]
        )
    ]

    public static let localTranscriptionOptions: [Option] = localTranscription.map(\.option)

    public static let allOptions: [Option] = liveTranscription + batchTranscription + localTranscriptionOptions + postProcessing

    // O(1) lookup cache keyed on lowercased model ID (first entry wins for cross-category duplicates).
    private static let optionsByID: [String: Option] = Dictionary(
        allOptions.map { ($0.id.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    public static func friendlyName(for identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }

        if let exact = optionsByID[trimmed.lowercased()] {
            return exact.displayName
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("local/") {
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
            .replacingOccurrences(of: #"(?i)\bq([0-9])\s+k\s+([a-z])\b"#, with: "Q$1_K_$2", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b([0-9]+)mb\b"#, with: "$1 MB", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b([0-9]+)gb\b"#, with: "$1 GB", options: .regularExpression)
            .capitalized
            .replacingOccurrences(of: "Gguf", with: "GGUF")
            .replacingOccurrences(of: " Mb", with: " MB")
            .replacingOccurrences(of: " Gb", with: " GB")
            .replacingOccurrences(of: "Qwen", with: "Qwen")
    }
}
