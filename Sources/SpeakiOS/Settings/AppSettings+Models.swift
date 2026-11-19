#if os(iOS)
import Foundation
import SpeakCore

/// Which shared catalogue models this iPhone build can select.
extension AppSettings {
    /// Identifiers this build can actually select for live transcription.
    static var selectableLiveModelIDs: Set<String> {
        Set((ModelCatalog.onDeviceLiveTranscription + supportedLiveModels).map(\.id))
    }

    /// Remote streaming models with an implemented iOS recording path. Shared
    /// catalogue entries that remain macOS-only are omitted rather than shown
    /// disabled or silently routed to a different provider.
    public static let supportedLiveModels: [ModelCatalog.Option] =
        ModelCatalog.remoteLiveTranscription.filter { option in
            LiveTranscriptionRouting.route(for: option.id)?.isSupportedOnIOS == true
        }

    /// Catalogue batch models with an iOS upload path. An entry without one
    /// stays hidden rather than falling through to OpenRouter.
    public static let supportedBatchModels: [ModelCatalog.Option] =
        ModelCatalog.batchTranscription.filter { option in
            AppleLocalModels.isSpeechAnalyzerModel(option.id)
                || openAIBatchModelIDs.contains(option.id)
                || AzureTranscriptionModels.batchIDs.contains(option.id)
                || AlibabaSpeechModels.batchIDs.contains(option.id)
                // OpenRouter-routed Gemini batch models upload through the
                // OpenRouter client; Gemini 3.5 Transcribe uploads through the
                // shared `GeminiInteractionsClient` with the Google key
                // (issue #862). Both are listed, and `batchAPIKey(for:)` and
                // `IOSBatchTranscriptionRoute` keep them on separate paths.
                || GeminiTranscribeModels.directBatchModelIDs.contains(option.id)
                || OpenRouterInlineAudioTranscriptionClient.batchCatalogIDs.contains(option.id)
                || option.id == MetaMuseVoiceTranscribe.batchCatalogID
                || option.id == CartesiaBatchClient.catalogID
                // xAI's dedicated speech-to-text endpoint uploads through the
                // shared `XAIBatchTranscriptionClient` with the xAI key.
                || option.id == XAISpeechToText.batchCatalogID
                || FileSpeechProvider.provider(for: option.id) != nil
                // Gladia's pre-recorded job API uploads through the shared
                // `GladiaBatchClient` with the `gladia.apiKey` this app already
                // stores for live Solaria.
                || option.id == GladiaBatchClient.catalogID
                // Deepgram, AssemblyAI, ElevenLabs, Groq, Mistral, Modulate,
                // Rev AI, Soniox and Speechmatics upload through their shared SpeakCore
                // clients with the provider's own key (issue #1636).
                || isSharedClientBatchModel(option.id)
        }

    static func isSharedClientBatchModel(_ id: String) -> Bool {
        guard let route = BatchTranscriptionRouting.route(for: id, platform: .iOS),
              route.transport == .directProvider else { return false }
        return BatchTranscriptionRouting.iosSharedClientProviderIDs.contains(route.providerID)
    }

    public static let openAIBatchModelIDs = OpenAITranscriptionModels.directBatchModelIDs

    public static let defaultPostProcessingPrompt = TranscriptCleanupPolicy.baseSystemPrompt

    /// Native text providers whose cleanup routes this app runs. Groq's key is
    /// stored for batch transcription only; its cleanup routes stay macOS/desktop-only.
    static let nativeTextProviderIDs: Set<String> = ["anthropic", "google", "mistral", "openai"]

    public static let postProcessingModels = ModelCatalog.postProcessing.filter {
        !$0.id.hasPrefix("local/post-processing/")
            && (NativeTextModels.route(for: $0.id).map { nativeTextProviderIDs.contains($0.provider.id) } ?? true)
    }
}
#endif
