#if os(iOS)
import Foundation
import SpeakCore

/// API-key identifiers, the canonical store and the lookups that resolve a
/// model's credential from the published key values.
extension AppSettings {
    // MARK: - Canonical secure storage for API keys (SpeakCore)
    //
    // Every API key is stored locally through SpeakCore's SecureStorage using the
    // same service/account as the macOS app. Cross-device transfer is handled only
    // by the explicit passphrase-encrypted CloudKit sync feature below; the base
    // Keychain item is deliberately not kSecAttrSynchronizable.
    static let deepgramKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "deepgram")
    static let openRouterKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "openrouter")
    static let openAIKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "openai")
    static let elevenLabsKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "elevenlabs")
    static let cartesiaKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "cartesia")
    static let sonioxKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "soniox")
    static let modulateKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "modulate")
    static let assemblyAIKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "assemblyai")
    static let gladiaKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "gladia")
    static let googleKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "google")
    static let xAIKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "xai")
    static let azureKeyID = AzureSpeechConfiguration.credentialIdentifier
    static let alibabaKeyID = AlibabaSpeechConfiguration.credentialIdentifier
    static let metaKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "meta")
    static let speechmaticsKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "speechmatics")
    static let revAIKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "revai")
    static let mistralKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "mistral")
    static let anthropicKeyID = NativeTextModels.anthropic.credentialIdentifier
    static let stepfunKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "stepfun")
    static let groqKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "groq")
    static let reson8KeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "reson8")
    static let smallestKeyID = ProviderCredentialCatalogue.apiKeyIdentifier(for: "smallest")

    private static let credentialStorage = SecureStorage(
        configuration: SecureStorageConfiguration(
            service: "com.github.speakapp.credentials",
            masterAccount: "speak-app-secrets",
            legacyServices: ["com.justspeaktoit.credentials"],
            accessibility: .afterFirstUnlock
        )
    )

    /// The canonical API-key store, exposed so QR config transfer reads and
    /// writes the same keychain items the rest of the app uses. Exporting or
    /// importing against any other service silently produces keys the app
    /// never sees.
    static var canonicalCredentialStorage: SecureStorage { credentialStorage }

    /// Every stored key the app reloads from the Keychain, in reload order.
    static var syncedAPIKeys: [(keyPath: ReferenceWritableKeyPath<AppSettings, String>, identifier: String)] {
        [
            (\.deepgramAPIKey, deepgramKeyID), (\.openRouterAPIKey, openRouterKeyID),
            (\.openAIAPIKey, openAIKeyID), (\.elevenLabsAPIKey, elevenLabsKeyID),
            (\.cartesiaAPIKey, cartesiaKeyID), (\.sonioxAPIKey, sonioxKeyID),
            (\.modulateAPIKey, modulateKeyID), (\.assemblyAIAPIKey, assemblyAIKeyID),
            (\.gladiaAPIKey, gladiaKeyID), (\.googleAPIKey, googleKeyID),
            (\.xAIAPIKey, xAIKeyID), (\.smallestAPIKey, smallestKeyID),
            (\.reson8APIKey, reson8KeyID), (\.stepfunAPIKey, stepfunKeyID),
            (\.azureAPIKey, azureKeyID), (\.alibabaAPIKey, alibabaKeyID),
            (\.metaAPIKey, metaKeyID), (\.speechmaticsAPIKey, speechmaticsKeyID),
            (\.revAIAPIKey, revAIKeyID), (\.mistralAPIKey, mistralKeyID),
            (\.anthropicAPIKey, anthropicKeyID), (\.groqAPIKey, groqKeyID)
        ]
    }

    public var hasDeepgramKey: Bool { !deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasOpenRouterKey: Bool { !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasOpenAIKey: Bool { !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasElevenLabsKey: Bool { !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasCartesiaKey: Bool { !cartesiaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasSonioxKey: Bool { !sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasModulateKey: Bool { !modulateAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasAssemblyAIKey: Bool { !assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasGladiaKey: Bool { !gladiaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasGoogleKey: Bool { !googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasXAIKey: Bool { !xAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasAzureKey: Bool { !azureAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasAlibabaKey: Bool { !alibabaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasMetaKey: Bool { !metaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasSpeechmaticsKey: Bool {
        !speechmaticsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var hasRevAIKey: Bool { !revAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasMistralKey: Bool { !mistralAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasAnthropicKey: Bool { !anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasGroqKey: Bool { !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Identifiers currently available to model pickers. Because this is
    /// derived from the published key values, readiness badges refresh as soon
    /// as a key is saved, synced, or removed.
    public var storedAPIKeyIdentifiers: Set<String> {
        var identifiers: Set<String> = []
        if hasDeepgramKey { identifiers.insert(Self.deepgramKeyID) }
        if hasOpenRouterKey { identifiers.insert(Self.openRouterKeyID) }
        if hasOpenAIKey { identifiers.insert(Self.openAIKeyID) }
        if hasElevenLabsKey { identifiers.insert(Self.elevenLabsKeyID) }
        if hasCartesiaKey { identifiers.insert(Self.cartesiaKeyID) }
        if hasSonioxKey { identifiers.insert(Self.sonioxKeyID) }
        if hasModulateKey { identifiers.insert(Self.modulateKeyID) }
        if hasAssemblyAIKey { identifiers.insert(Self.assemblyAIKeyID) }
        if hasGladiaKey { identifiers.insert(Self.gladiaKeyID) }
        if hasGoogleKey { identifiers.insert(Self.googleKeyID) }
        if hasXAIKey { identifiers.insert(Self.xAIKeyID) }
        for provider in FileSpeechProvider.allCases {
            if let key = apiKeysByIdentifier[provider.metadata.apiKeyIdentifier],
               !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                identifiers.insert(provider.metadata.apiKeyIdentifier)
            }
        }
        if hasAzureKey { identifiers.insert(Self.azureKeyID) }
        if hasAlibabaKey { identifiers.insert(Self.alibabaKeyID) }
        if hasMetaKey { identifiers.insert(Self.metaKeyID) }
        if hasSpeechmaticsKey { identifiers.insert(Self.speechmaticsKeyID) }
        if hasRevAIKey { identifiers.insert(Self.revAIKeyID) }
        if hasMistralKey { identifiers.insert(Self.mistralKeyID) }
        if hasAnthropicKey { identifiers.insert(Self.anthropicKeyID) }
        if hasGroqKey { identifiers.insert(Self.groqKeyID) }
        return identifiers
    }

    /// Returns the stored API key for a resolved live-transcription route, used
    /// by the generic shared-client recording path.
    public func liveAPIKey(for route: LiveTranscriptionRoute) -> String {
        guard let identifier = route.apiKeyIdentifier else { return "" }
        return liveAPIKeysByIdentifier[identifier] ?? ""
    }

    /// Every cloud live-transcription credential this app stores, keyed by the
    /// identifier `LiveTranscriptionRoute` resolves to. A table rather than a
    /// switch so adding a provider is one line and the lookup stays flat.
    private var liveAPIKeysByIdentifier: [String: String] {
        [
            Self.deepgramKeyID: deepgramAPIKey,
            Self.openAIKeyID: openAIAPIKey,
            Self.elevenLabsKeyID: elevenLabsAPIKey,
            Self.cartesiaKeyID: cartesiaAPIKey,
            Self.sonioxKeyID: sonioxAPIKey,
            Self.modulateKeyID: modulateAPIKey,
            Self.assemblyAIKeyID: assemblyAIAPIKey,
            Self.gladiaKeyID: gladiaAPIKey,
            Self.googleKeyID: googleAPIKey,
            Self.xAIKeyID: xAIAPIKey,
            Self.reson8KeyID: reson8APIKey,
            Self.metaKeyID: metaAPIKey,
            Self.speechmaticsKeyID: speechmaticsAPIKey,
            Self.revAIKeyID: revAIAPIKey,
            Self.mistralKeyID: mistralAPIKey,
            Self.azureKeyID: azureAPIKey,
            Self.alibabaKeyID: alibabaAPIKey
        ]
    }

    public var batchAPIKey: String {
        batchAPIKey(for: batchTranscriptionModel)
    }

    /// Batch credentials resolve through the same canonical mapping the
    /// pickers and macOS use, so a directly-served model (OpenAI, Meta Muse,
    /// Gemini 3.5 Transcribe) never silently falls back to the OpenRouter key.
    /// Identifiers this app does not store keep the OpenRouter fallback, which
    /// is the route `IOSBatchTranscriber` takes for those models.
    public func batchAPIKey(for modelIdentifier: String) -> String {
        switch ModelCredentialResolver.requirement(
            for: modelIdentifier, purpose: .batchTranscription
        ) {
        case .notRequired:
            return ""
        case .apiKey(let identifier, _):
            return apiKeysByIdentifier[identifier] ?? openRouterAPIKey
        }
    }

    /// The key the post-processing model's route needs: the provider's own key
    /// for a native model, the OpenRouter key otherwise, and "" on device.
    public func postProcessingAPIKey(for modelIdentifier: String) -> String {
        switch ModelCredentialResolver.requirement(for: modelIdentifier, purpose: .postProcessing) {
        case .notRequired:
            return ""
        case .apiKey(let identifier, _):
            return apiKeysByIdentifier[identifier] ?? ""
        }
    }

    public func hasPostProcessingKey(for modelIdentifier: String) -> Bool {
        if case .notRequired = ModelCredentialResolver.requirement(for: modelIdentifier, purpose: .postProcessing) {
            return true
        }
        return !postProcessingAPIKey(for: modelIdentifier).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the selected post-processing model can run with the stored keys.
    public var hasPostProcessingKey: Bool { hasPostProcessingKey(for: postProcessingModel) }

    /// The provider name the selected post-processing model needs a key for.
    public var postProcessingKeyProviderName: String {
        if case .apiKey(_, let providerName) = ModelCredentialResolver.requirement(
            for: postProcessingModel, purpose: .postProcessing
        ) { return providerName }
        return "OpenRouter"
    }

    /// Every stored transcription credential keyed by its canonical
    /// identifier, so credential lookups stay a table rather than a switch.
    private var apiKeysByIdentifier: [String: String] {
        var keys = liveAPIKeysByIdentifier
        keys[Self.openRouterKeyID] = openRouterAPIKey
        keys[Self.anthropicKeyID] = anthropicAPIKey
        keys[Self.smallestKeyID] = smallestAPIKey
        keys[Self.stepfunKeyID] = stepfunAPIKey
        keys[Self.groqKeyID] = groqAPIKey
        return keys
    }
}
#endif
