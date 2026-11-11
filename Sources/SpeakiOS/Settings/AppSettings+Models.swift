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

    /// iOS currently supports OpenAI's transcription endpoint and OpenRouter's
    /// audio-capable batch models. Other catalogue entries remain shared with
    /// Mac but are hidden until their upload clients are available on iPhone.
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
                // stores for live Solaria. Speechmatics batch stays macOS-only
                // for now: iOS has no Speechmatics credential field, and a
                // model that can never resolve a key is hidden rather than
                // shown failing (see Docs/batch-transcription-providers.md).
                || option.id == GladiaBatchClient.catalogID
        }

    public static let openAIBatchModelIDs = OpenAITranscriptionModels.directBatchModelIDs

    public static let defaultPostProcessingPrompt = TranscriptCleanupPolicy.baseSystemPrompt

    /// Native text providers whose key this app stores. Groq has no iOS key slot,
    /// so its native cleanup routes stay macOS/desktop-only.
    static let nativeTextProviderIDs: Set<String> = ["openai", "google", "mistral"]

    public static let postProcessingModels = ModelCatalog.postProcessing.filter {
        !$0.id.hasPrefix("local/post-processing/")
            && (NativeTextModels.route(for: $0.id).map { nativeTextProviderIDs.contains($0.provider.id) } ?? true)
    }
}
#endif
