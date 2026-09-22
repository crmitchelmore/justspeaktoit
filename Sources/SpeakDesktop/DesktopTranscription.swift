import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// A projection of the canonical catalogue, limited to transports wired into
/// the desktop host. Adding a catalogue entry does not claim OS/runtime support.
public enum DesktopTranscription {
    public static var batchModels: [ModelCatalog.Option] {
        ModelCatalog.batchTranscription.filter { backend(for: $0.id) != nil }
    }

    /// The same credential identifier, provider name and account-creation URL
    /// the Apple surfaces use. Unimplemented models never acquire a descriptor.
    public static func provider(for modelID: String) -> TranscriptionProviderMetadata? {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let backend = backend(for: identifier),
              case .apiKey(let credentialID, let providerName) = ModelCredentialResolver.requirement(
                for: identifier, purpose: .batchTranscription
              ),
              let providerID = ModelRouting.family(for: identifier).providerID else { return nil }
        let website: String
        if case .groq = backend {
            website = GroqBatchClient().metadata.website
        } else {
            website = LiveTranscriptionProviderID(rawValue: providerID)?.apiKeyURL?.absoluteString ?? ""
        }
        return TranscriptionProviderMetadata(
            id: providerID,
            displayName: providerName,
            website: website,
            apiKeyIdentifier: credentialID
        )
    }

    public static func transcribe(
        audioURL: URL,
        model: String,
        apiKey: String,
        duration: TimeInterval,
        language: String? = nil,
        azureEndpoint: String = "",
        staging: SharedMultipartUploadStaging? = nil
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioURL: audioURL, model: model, apiKey: apiKey, duration: duration,
            language: language, azureEndpoint: azureEndpoint, staging: staging, session: .shared
        )
    }

    /// Session injection exercises the real provider clients in contract tests;
    /// endpoint, request, response and job-cleanup logic remain in SpeakCore.
    static func transcribe(
        audioURL: URL,
        model: String,
        apiKey: String,
        duration: TimeInterval,
        language: String? = nil,
        azureEndpoint: String = "",
        staging: SharedMultipartUploadStaging? = nil,
        session: URLSession
    ) async throws -> TranscriptionResult {
        let identifier = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let backend = backend(for: identifier) else {
            throw DesktopTranscriptionError.unsupportedModel
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        try Task.checkCancellation()
        do {
            return try await transcribe(
                Request(
                    audioURL: audioURL, model: identifier, apiKey: key, duration: duration,
                    language: language, azureEndpoint: azureEndpoint, staging: staging
                ),
                using: backend, session: session
            )
        } catch {
            // URLSession may report cancellation as URLError.cancelled. Keep
            // cancellation distinct from a failed recording on every route.
            throw BatchTranscriptionJob.mapCancellation(error)
        }
    }

    private struct Request: Sendable {
        let audioURL: URL
        let model: String
        let apiKey: String
        let duration: TimeInterval
        let language: String?
        let azureEndpoint: String
        let staging: SharedMultipartUploadStaging?
    }

    private static func transcribe(
        _ input: Request, using backend: Backend, session: URLSession
    ) async throws -> TranscriptionResult {
        switch backend {
        case .prepared(let provider):
            return try await transcribePrepared(input, using: provider, session: session)
        case .openai:
            return try await OpenAIBatchClient(session: session, durationResolver: { _ in input.duration })
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .groq:
            return try await GroqBatchClient(session: session, durationResolver: { _ in input.duration })
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .deepgram:
            return try await DeepgramBatchClient(session: session, durationResolver: { _ in input.duration })
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .elevenlabs:
            return try await ElevenLabsBatchClient(session: session, durationResolver: { _ in input.duration })
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .google:
            return try await GeminiInteractionsClient(session: session, durationResolver: { _ in input.duration })
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .xai:
            return try await XAIBatchTranscriptionClient(session: session)
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, language: input.language)
        case .cartesia:
            return try await CartesiaBatchClient(session: session)
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, language: input.language)
        case .gladia:
            return try await GladiaBatchClient(session: session)
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .speechmatics:
            return try await SpeechmaticsBatchClient(session: session)
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        }
    }

    private enum PreparedProvider: Sendable { case meta, azure, mistral, soniox }

    private static func transcribePrepared(
        _ input: Request, using provider: PreparedProvider, session: URLSession
    ) async throws -> TranscriptionResult {
        switch provider {
        case .soniox:
            return try await SonioxBatchClient(session: session, multipartStaging: secureStaging(input.staging))
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .mistral:
            return try await MistralBatchClient(
                session: session, multipartStaging: secureStaging(input.staging),
                durationResolver: { _ in input.duration }
            ).transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .meta:
            return try await MetaMuseBatchClient(session: session)
                .transcribeFile(at: input.audioURL, apiKey: input.apiKey, model: input.model, language: input.language)
        case .azure:
            return try await AzureBatchTranscriptionClient(session: session).transcribeFile(
                at: input.audioURL, credentials: input.apiKey, endpoint: input.azureEndpoint,
                model: input.model, language: input.language
            )
        }
    }

    /// Windows callers must supply a native ACL policy. POSIX consumers retain
    /// the existing private directory/file permissions and shared claim registry.
    private static func secureStaging(
        _ supplied: SharedMultipartUploadStaging?
    ) throws -> SharedMultipartUploadStaging {
        if let supplied { return supplied }
        #if os(Windows)
        throw DesktopTranscriptionError.secureStagingUnavailable
        #else
        return .posixShared
        #endif
    }

    private enum Backend: Sendable {
        case prepared(PreparedProvider)
        case openai
        case groq
        case deepgram
        case xai
        case elevenlabs
        case google
        case cartesia
        case gladia
        case speechmatics
    }

    /// One mapping controls discovery, credentials and execution. Model entries
    /// and defaults continue to be owned by the shared catalogue and clients.
    private static func backend(for model: String) -> Backend? {
        if let backend = fixedBackends[model] { return backend }
        // These clients accept every batch model owned by their canonical
        // provider catalogue. Unknown and streaming identifiers stay hidden.
        if case .cloudBatch(let provider) = ModelRouting.family(for: model) {
            if provider == "groq" { return .groq }
            if provider == "deepgram" { return .deepgram }
            if provider == "elevenlabs" { return .elevenlabs }
            if provider == "mistral" { return .prepared(.mistral) }
            if provider == "soniox" { return .prepared(.soniox) }
        }
        return nil
    }

    private static let fixedBackends: [String: Backend] = {
        var mappings: [String: Backend] = [
            MetaMuseVoiceTranscribe.batchCatalogID: .prepared(.meta),
            XAISpeechToText.batchCatalogID: .xai,
            CartesiaBatchClient.catalogID: .cartesia,
            GladiaBatchClient.catalogID: .gladia
        ]
        for model in AzureTranscriptionModels.batchIDs { mappings[model] = .prepared(.azure) }
        for model in GeminiTranscribeModels.directBatchModelIDs { mappings[model] = .google }
        for model in OpenAITranscriptionModels.directBatchModelIDs { mappings[model] = .openai }
        for model in SpeechmaticsBatchClient.catalogIDs { mappings[model] = .speechmatics }
        return mappings
    }()

}

public enum DesktopTranscriptionError: LocalizedError {
    case unsupportedModel
    case secureStagingUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            return "This model is not yet supported by the Windows recording workflow."
        case .secureStagingUnavailable:
            return "Private upload storage is unavailable. This provider cannot start transcription."
        }
    }
}
