#if os(iOS)
import SpeakCore
import os.log

private let apiKeysLogger = SpeakLogger.logger(category: "APIKeys")

/// Checks and stores one provider's key for the API Keys screen, and words the
/// line the Validation alert shows for it.
@MainActor
struct APIKeyCredentialWriter {
    let settings: AppSettings

    /// Unknown ids store the Gladia key, as they always have.
    private static let settingByEntryID: [String: ReferenceWritableKeyPath<AppSettings, String>] = [
        "deepgram": \.deepgramAPIKey,
        "elevenlabs": \.elevenLabsAPIKey,
        "openrouter": \.openRouterAPIKey,
        "openai": \.openAIAPIKey,
        "cartesia": \.cartesiaAPIKey,
        "soniox": \.sonioxAPIKey,
        "modulate": \.modulateAPIKey,
        "assemblyai": \.assemblyAIAPIKey,
        "google": \.googleAPIKey,
        "xai": \.xAIAPIKey,
        "smallest": \.smallestAPIKey,
        "reson8": \.reson8APIKey,
        "stepfun": \.stepfunAPIKey,
        "azure": \.azureAPIKey,
        "alibaba": \.alibabaAPIKey,
        "meta": \.metaAPIKey,
        "speechmatics": \.speechmaticsAPIKey,
        "revai": \.revAIAPIKey,
        "mistral": \.mistralAPIKey,
        "anthropic": \.anthropicAPIKey
    ]

    func store(_ key: String, for id: String) {
        settings[keyPath: Self.settingByEntryID[id] ?? \.gladiaAPIKey] = key
    }

    /// The alert line for a key its provider rejects, or nil when the key
    /// passed or the provider has no cheap probe; the others check the key
    /// when a session connects, and a stored key is never read as entitlement.
    ///
    /// Provider responses can echo account details or the submitted key, so
    /// the alert gets a fixed local line and the original goes to the private
    /// log.
    func validationFailure(of key: String, for id: String) async -> String? {
        let title = APIKeyProviderPresentation(entryID: id).title
        let outcome: APIKeyValidationResult.Outcome
        switch id {
        case "alibaba":
            do {
                _ = try AlibabaSpeechConfiguration(credentials: key)
                return nil
            } catch { return error.localizedDescription }
        case "azure":
            do {
                _ = try await AzureSpeechVoiceAPI().listVoices(credentials: key)
                return nil
            } catch {
                SpeakLogger.logError(error, context: "Azure Speech key validation", logger: apiKeysLogger)
                return "✗ \(title): the key and region could not be verified, so they were not saved."
            }
        case "deepgram":
            outcome = await DeepgramAPIKeyValidator().validate(key).outcome
        case "elevenlabs":
            outcome = await ElevenLabsSTTAPIKeyValidator().validate(key).outcome
        case "meta":
            outcome = await MetaMuseAPIKeyValidator().validate(key).outcome
        default:
            return nil
        }
        guard case .failure(let detail) = outcome else { return nil }
        apiKeysLogger.error(
            "API key validation failed for \(id, privacy: .public): \(detail, privacy: .private)"
        )
        return "✗ \(title): the key could not be verified, so it was not saved. Check it and try again."
    }

    static func savedMessage(for id: String, title: String) -> String {
        switch id {
        case "alibaba":
            return "✓ Alibaba key, region and workspace saved. Access is checked when transcribing."
        case "azure":
            return "✓ Azure key and region saved; transcription access depends on your resource."
        case "deepgram", "elevenlabs":
            return "✓ \(title) key validated and saved"
        case "meta":
            return "✓ Meta key validated for Muse Voice Transcribe and saved"
        case "soniox":
            return "✓ Soniox key saved for transcription and voice output"
        case "revai":
            return "✓ Rev.ai access token saved"
        default:
            return "✓ \(title) key saved"
        }
    }
}
#endif
