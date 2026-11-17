import Foundation

/// On-device models that only the Android app can run.
///
/// Capability rule: Gemini Nano runs through Android's AICore system service, reached with the ML Kit
/// GenAI Prompt API, so it is offered only on Android and only where ML Kit's `checkStatus()` reports it
/// available, downloadable or downloading. macOS, iOS, Windows and Linux never list it, and it never
/// joins `ModelCatalog.postProcessing` or `cloudPostProcessing`. A synced or imported
/// `android/local/GeminiNano` selection therefore normalises to the default cloud model elsewhere
/// (`ModelCatalog.normalizedPostProcessingModel`), while History still shows its name. On Android a
/// failure keeps the original transcript; it is never silently replaced by a cloud route.
/// See Docs/android-on-device-models.md.
public enum AndroidLocalModels {
    /// Gemini Nano through the ML Kit GenAI Prompt API (`com.google.mlkit:genai-prompt`).
    public static let geminiNanoID = "android/local/GeminiNano"

    /// ML Kit's documented Prompt API input limit. A longer request keeps the original transcript.
    public static let geminiNanoInputTokenLimit = 4_000

    public static let geminiNano = ModelCatalog.Option(
        id: geminiNanoID,
        displayName: "Gemini Nano (On-device)",
        description: "Cleans up transcripts on the phone with Android's built-in Gemini Nano, "
            + "on supported Pixel and Samsung devices. The transcript never leaves the device.",
        estimatedLatencyMs: 1_500,
        latencyTier: .fast,
        tags: [.fast, .privacy]
    )

    public static func isGeminiNano(_ identifier: String) -> Bool {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == geminiNanoID.lowercased()
    }
}
