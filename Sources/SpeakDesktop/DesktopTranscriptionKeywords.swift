import SpeakCore

extension DesktopTranscription {
    /// A route may run without supporting a recognition glossary. Do not send
    /// speculative fields or change annotation/formatting modes to force one.
    public static func keywordLimitation(model: String) -> String? { // swiftlint:disable:this cyclomatic_complexity
        if let route = DesktopLiveTranscription.route(forID: model) {
            switch route.provider {
            case .openai:
                if OpenAITranscriptionModels.supportsRealtimePrompt(route.apiModelName) { return nil }
            case .deepgram, .assemblyai, .speechmatics, .soniox, .xai, .google, .meta, .elevenlabs:
                return nil
            default: break
            }
        } else if let provider = provider(for: model) {
            switch provider.id {
            case "openai", "groq":
                let name = model.split(separator: "/").last.map(String.init) ?? model
                if OpenAITranscriptionModels.supportsBatchPrompt(name) { return nil }
            case "deepgram", "assemblyai", "speechmatics", "soniox", "xai", "meta", "azure":
                return nil
            case "elevenlabs":
                if model == ModelCatalog.elevenLabsScribeV2BatchID { return nil }
            case "mistral":
                if MistralBatchClient.supportsKeywords(model: model) { return nil }
            case "google":
                return "Shared keywords are not sent to Gemini batch: word timestamps and speaker diarization "
                    + "are retained and cannot be combined with custom vocabulary."
            default: break
            }
        }
        return "Shared keywords are not sent to this model: its desktop shared client has no qualified "
            + "recognition-vocabulary mapping. Transcription uses the model's normal behavior."
    }
}
