import Foundation

extension SettingsSearchCatalog {
    static let transcriptionEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "transcription.mode", title: "Transcription mode", section: .transcription, systemImage: "waveform",
            summary: "Choose local or remote, and batch or streaming transcription.",
            keywords: [
                "where transcription runs", "local", "remote", "batch", "streaming", "live", "on device",
                "local transcription source", "remote transcription type", "downloaded transcription type"
            ],
            settingKeys: [
                "transcriptionMode", "rememberedLocalTranscriptionSource", "rememberedRemoteTranscriptionMode",
                "localTranscriptionMode"
            ],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.remoteStreamingModel", title: "Remote Streaming model", section: .transcription,
            systemImage: "mic.fill",
            summary: "The live transcription model. Shown when remote streaming is selected.",
            keywords: [
                "live model", "deepgram", "assemblyai", "openai realtime", "speechmatics", "soniox", "model picker"
            ],
            settingKeys: ["liveTranscriptionModel"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.remoteBatchModel", title: "Remote Batch model", section: .transcription,
            systemImage: "folder.badge.clock",
            summary: "The model used after you stop recording. Shown when remote batch is selected.",
            keywords: ["batch model", "whisper", "gpt transcribe", "openrouter", "model picker", "file transcription"],
            settingKeys: ["batchTranscriptionModel"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.appleOnDevice", title: "Apple on-device transcription", section: .transcription,
            systemImage: "apple.logo",
            summary: "Apple Speech running privately on this Mac.",
            keywords: ["apple speech", "speechanalyzer", "private", "offline", "on device"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.localModels", title: "Local transcription models", section: .transcription,
            systemImage: "externaldrive",
            summary: "Download, import and choose local models such as Whisper and Parakeet.",
            keywords: [
                "download model", "whisperkit", "parakeet", "hugging face", "import model", "offline", "sherpa",
                "advanced model configuration"
            ],
            settingKeys: ["localTranscriptionModel", "localStreamingModelSource"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.processingSpeed", title: "Processing Speed", section: .transcription,
            systemImage: "speedometer",
            summary: "Instant or live polish while streaming.",
            keywords: ["instant", "live polish", "speed mode", "latency", "polish while speaking"],
            settingKeys: [
                "speedMode", "livePolishModel", "livePolishDebounceMs", "livePolishMinDeltaChars",
                "livePolishTailWindowChars", "skipPostProcessingWithLivePolish"
            ],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.savedKeywordEdits", title: "Saved keyword edits", section: .transcription,
            systemImage: "arrow.uturn.backward",
            summary: "Restore or discard keyword edits saved from an earlier session.",
            keywords: ["restore keywords", "discard saved edit", "recovered keywords"],
            settingKeys: ["recoveredTranscriptionKeywords"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.metaMuse", title: "Meta Muse recognition bias", section: .transcription,
            systemImage: "textformat.abc",
            summary: "Bias Meta Muse recognition towards your terms.",
            keywords: ["keyterms", "vocabulary", "meta"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.handsFree", title: "Hands-free dictation", section: .transcription,
            systemImage: "hand.raised",
            summary: "Arm dictation and let speech start and stop recording.",
            keywords: ["arm on hotkey instead of recording", "voice activated", "vad", "hands free"],
            settingKeys: ["handsFreeDictationEnabled"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.silenceDetection", title: "Silence detection", section: .transcription,
            systemImage: "waveform.slash",
            summary: "Stop recording automatically after a period of silence.",
            keywords: ["auto-stop on silence", "silence threshold", "silence duration", "auto stop", "pause"],
            settingKeys: ["silenceDetectionEnabled", "silenceThreshold", "silenceDuration"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.streamingStopGrace", title: "Streaming stop grace", section: .transcription,
            systemImage: "timer",
            summary: "How long to wait for final streaming text after you stop.",
            keywords: ["grace period", "cut off", "last words missing", "stop delay"],
            settingKeys: ["liveStopGracePeriod"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.recordingBuffer", title: "Recording buffer", section: .transcription,
            systemImage: "waveform.path.ecg",
            summary: "Keep recording briefly after you stop so the last words are captured.",
            keywords: ["tail duration", "last words missing", "cut off", "post recording"],
            settingKeys: ["postRecordingTailDuration"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "transcription.modelsChosenForYou", title: "Models chosen for you", section: .transcription,
            systemImage: "sparkles",
            summary: "Simple model choices picked by your subscription.",
            keywords: ["simple model choices", "subscription", "paid access"],
            settingKeys: ["simpleModelChoices"], platforms: .macOS
        )
    ]

    static let postProcessingEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "postProcessing.cleanup", title: "Cleanup", section: .postProcessing, systemImage: "wand.and.stars",
            summary: "Turn LLM cleanup on and choose a local or cloud model.",
            keywords: [
                "enable post-processing", "polish", "llm", "openrouter", "local llm", "cleanup model", "temperature",
                "system prompt", "custom prompt", "rewrite", "grammar", "stream cleanup"
            ],
            settingKeys: [
                "postProcessingEnabled", "postProcessingModel", "postProcessingTemperature",
                "postProcessingStreamingEnabled"
            ],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "postProcessing.cleanupContext", title: "Cleanup Context", section: .postProcessing,
            systemImage: "gearshape.2",
            summary: "Output language, lexicon directives, context tags and model discovery.",
            keywords: [
                "output language", "include context tags", "include personal lexicon directives", "translate",
                "model discovery"
            ],
            settingKeys: [
                "postProcessingOutputLanguage", "postProcessingIncludeLexiconDirectives",
                "postProcessingIncludeContextTags", "cleanupModelDiscoveryEnabled"
            ],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "postProcessing.preProcessing", title: "Pre-processing", section: .postProcessing,
            systemImage: "bolt.fill",
            summary: "AssemblyAI formats each turn itself; keyterms bias recognition.",
            keywords: ["assemblyai", "contextual prompt", "formatted turns"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "postProcessing.keyterms", title: "Keyterms", section: .postProcessing, systemImage: "textformat.abc",
            summary: "Words and names transcription should recognise.",
            keywords: ["keywords", "vocabulary", "custom words", "jargon", "names", "boost"],
            settingKeys: ["assemblyAIKeyterms", "transcriptionKeywords"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "postProcessing.modulate", title: "Modulate features", section: .postProcessing,
            systemImage: "person.wave.2",
            summary: "Speaker diarisation, emotion, accent and PII tagging for Modulate models.",
            keywords: [
                "speaker diarisation", "diarization", "emotion detection", "accent detection", "pii/phi tagging",
                "redaction"
            ],
            settingKeys: [
                "modulateSpeakerDiarizationEnabled", "modulateEmotionSignalEnabled", "modulateAccentSignalEnabled",
                "modulatePIIPhiTaggingEnabled"
            ],
            platforms: .macOS
        )
    ]
}
