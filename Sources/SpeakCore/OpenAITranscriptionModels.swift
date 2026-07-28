import Foundation

/// OpenAI speech-to-text identifiers and wire-format differences shared by
/// the macOS and iOS transcription clients.
public enum OpenAITranscriptionModels {
    public static let gptTranscribeCatalogID = "openai/gpt-transcribe"
    public static let gptLiveTranscribeStreamingCatalogID = "openai/gpt-live-transcribe-streaming"

    public static let gptTranscribeAPIName = "gpt-transcribe"
    public static let gptLiveTranscribeAPIName = "gpt-live-transcribe"

    /// Models sent directly to OpenAI's `/v1/audio/transcriptions` endpoint.
    public static let directBatchModelIDs: Set<String> = [
        "openai/whisper-1",
        gptTranscribeCatalogID,
        "openai/gpt-4o-mini-transcribe",
        "openai/gpt-4o-transcribe",
        "openai/gpt-4o-transcribe-diarize"
    ]

    /// Converts a catalogue identifier to the model name expected by OpenAI.
    public static func apiModelName(from identifier: String) -> String {
        var name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("openai/") {
            name = String(name.dropFirst("openai/".count))
        }
        if name.hasSuffix("-streaming") {
            name = String(name.dropLast("-streaming".count))
        }
        return name
    }

    /// The new GPT transcription family accepts an array of language hints.
    /// Existing GPT-4o and Whisper integrations retain the singular field.
    public static func usesLanguageHintsArray(_ apiModelName: String) -> Bool {
        belongs(apiModelName, to: gptTranscribeAPIName)
            || belongs(apiModelName, to: gptLiveTranscribeAPIName)
    }

    /// Returns the multipart field name used for this model's language hint.
    public static func batchLanguageFieldName(for apiModelName: String) -> String {
        usesLanguageHintsArray(apiModelName) ? "languages[]" : "language"
    }

    /// Builds the GA Realtime transcription-session update used on both
    /// platforms, including each model family's language and prompt semantics.
    public static func realtimeSessionUpdatePayload(
        model: String,
        language: String?,
        prompt: String?,
        sampleRate: Int
    ) -> [String: Any] {
        let apiModelName = apiModelName(from: model)
        var transcription: [String: Any] = ["model": apiModelName]

        if let language = nonEmpty(language) {
            if usesLanguageHintsArray(apiModelName) {
                transcription["languages"] = [language]
            } else {
                transcription["language"] = language
            }
        }

        if let prompt = nonEmpty(prompt), supportsRealtimePrompt(apiModelName) {
            transcription["prompt"] = prompt
        }

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "transcription": transcription,
                        "noise_reduction": ["type": "near_field"],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
    }

    /// Whether a Realtime transcription session accepts prompt-based context.
    public static func supportsRealtimePrompt(_ modelName: String) -> Bool {
        let normalised = apiModelName(from: modelName).lowercased()
        return belongs(normalised, to: gptTranscribeAPIName)
            || belongs(normalised, to: gptLiveTranscribeAPIName)
            || normalised.hasPrefix("gpt-4o-transcribe")
            || normalised.hasPrefix("gpt-4o-mini-transcribe")
    }

    private static func belongs(_ modelName: String, to family: String) -> Bool {
        let normalised = apiModelName(from: modelName).lowercased()
        return normalised == family || normalised.hasPrefix("\(family)-")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
