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
        language: String? = nil
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioURL: audioURL, model: model, apiKey: apiKey, duration: duration,
            language: language, session: .shared
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
                Request(audioURL: audioURL, model: identifier, apiKey: key, duration: duration, language: language),
                using: backend, session: session
            )
        } catch {
            // URLSession may report cancellation as URLError.cancelled. Keep
            // cancellation distinct from a failed recording on every route.
            throw BatchTranscriptionJob.mapCancellation(error)
        }
    }

    private struct Request {
        let audioURL: URL
        let model: String
        let apiKey: String
        let duration: TimeInterval
        let language: String?
    }

    private static func transcribe(
        _ input: Request, using backend: Backend, session: URLSession
    ) async throws -> TranscriptionResult {
        switch backend {
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

    private enum Backend {
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
        if GeminiTranscribeModels.directBatchModelIDs.contains(model) { return .google }
        if model == XAISpeechToText.batchCatalogID { return .xai }
        // These clients accept every batch model owned by their canonical
        // provider catalogue. Unknown and streaming identifiers stay hidden.
        if case .cloudBatch(let provider) = ModelRouting.family(for: model) {
            if provider == "groq" { return .groq }
            if provider == "deepgram" { return .deepgram }
            if provider == "elevenlabs" { return .elevenlabs }
        }
        if OpenAITranscriptionModels.directBatchModelIDs.contains(model) { return .openai }
        if model == CartesiaBatchClient.catalogID { return .cartesia }
        if model == GladiaBatchClient.catalogID { return .gladia }
        if SpeechmaticsBatchClient.catalogIDs.contains(model) { return .speechmatics }
        return nil
    }
}

public enum DesktopTranscriptionError: LocalizedError {
    case unsupportedModel

    public var errorDescription: String? {
        "This model is not yet supported by the Windows recording workflow."
    }
}
