import Foundation

/// Compatibility projections for the two existing Apple batch adapters.
/// Catalogue membership is ownership metadata, not permission to upload.
public enum BatchTranscriptionPlatform: Sendable {
    case macOS
    case iOS
}

public struct BatchTranscriptionRoute: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case appleLocal
        case directProvider
        case openRouter
    }

    public let modelID: String
    public let providerID: String
    public let transport: Transport
    /// The selected transport's canonical credential owner, not the provenance
    /// of an arbitrary caller-supplied key. Platform key loading is unchanged.
    public let apiKeyIdentifier: String?
    /// Only populated where an existing single wire-model projection is shared.
    /// Nil leaves multi-field, omitted and server-selected models in the client.
    public let apiModelName: String?
}

/// Shared ownership; endpoint, authentication, payload and validation remain in
/// provider clients. iOS deliberately retains its legacy unknown-ID OpenRouter
/// fallback. Mac unknown/non-batch ownership stays with the registered instance.
public enum BatchTranscriptionRouting {
    public static func route(for modelID: String, platform: BatchTranscriptionPlatform) -> BatchTranscriptionRoute? {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if AppleLocalModels.isSpeechAnalyzerModel(model) {
            return .init(modelID: model, providerID: "apple", transport: .appleLocal,
                         apiKeyIdentifier: nil, apiModelName: nil)
        }
        switch platform {
        case .iOS:
            return iosRoute(model)
        case .macOS:
            return macRoute(model)
        }
    }

    private static func macRoute(_ model: String) -> BatchTranscriptionRoute? {
        if model.hasPrefix(OpenRouterTranscriptionSelection.prefix) { return openRouter(model) }
        guard ModelCatalog.batchTranscription.contains(where: { $0.id == model }) else { return nil }
        switch ModelCredentialResolver.requirement(for: model, purpose: .batchTranscription) {
        case .notRequired:
            return nil
        case .apiKey(let identifier, _):
            if identifier == ProviderCredentialCatalogue.apiKeyIdentifier(for: "openrouter") {
                return openRouter(model)
            }
            guard let provider = model.split(separator: "/").first else { return nil }
            return direct(model, provider: String(provider))
        }
    }

    /// The established iOS capability projection and precedence. Do not enable
    /// another direct provider solely because it has a shared client on Mac.
    private static func iosRoute(_ model: String) -> BatchTranscriptionRoute {
        if OpenAITranscriptionModels.directBatchModelIDs.contains(model) { return direct(model, provider: "openai") }
        if model == CartesiaBatchClient.catalogID { return direct(model, provider: "cartesia") }
        if model == GladiaBatchClient.catalogID { return direct(model, provider: "gladia") }
        if AzureTranscriptionModels.batchIDs.contains(model) { return direct(model, provider: "azure") }
        // Invalid/retired Alibaba choices remain owned and rejected by its client.
        if model.hasPrefix("alibaba/") { return direct(model, provider: "alibaba") }
        if model == MetaMuseVoiceTranscribe.batchCatalogID { return direct(model, provider: "meta") }
        if GeminiTranscribeModels.directBatchModelIDs.contains(model) { return direct(model, provider: "google") }
        if model == XAISpeechToText.batchCatalogID { return direct(model, provider: "xai") }
        if let provider = FileSpeechProvider.provider(for: model) { return direct(model, provider: provider.rawValue) }
        return openRouter(model)
    }

    private static func direct(_ model: String, provider: String) -> BatchTranscriptionRoute {
        let apiModel: String?
        if OpenAITranscriptionModels.directBatchModelIDs.contains(model) {
            apiModel = OpenAITranscriptionModels.apiModelName(from: model)
        } else if GeminiTranscribeModels.directBatchModelIDs.contains(model) {
            apiModel = GeminiTranscribeModels.batchAPIName
        } else {
            apiModel = nil
        }
        return .init(modelID: model, providerID: provider, transport: .directProvider,
                     apiKeyIdentifier: ProviderCredentialCatalogue.apiKeyIdentifier(for: provider),
                     apiModelName: apiModel)
    }

    private static func openRouter(_ model: String) -> BatchTranscriptionRoute {
        let apiModel = model.hasPrefix(OpenRouterTranscriptionSelection.prefix)
            ? OpenRouterTranscriptionSelection.modelID(from: model) : model
        return .init(modelID: model, providerID: "openrouter", transport: .openRouter,
                     apiKeyIdentifier: ProviderCredentialCatalogue.apiKeyIdentifier(for: "openrouter"),
                     apiModelName: apiModel)
    }
}
