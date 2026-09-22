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
        guard backend(for: identifier) != nil,
              case .apiKey(let credentialID, let providerName) = ModelCredentialResolver.requirement(
                for: identifier, purpose: .batchTranscription
              ),
              let providerID = ModelRouting.family(for: identifier).providerID else { return nil }
        return TranscriptionProviderMetadata(
            id: providerID,
            displayName: providerName,
            website: LiveTranscriptionProviderID(rawValue: providerID)?.apiKeyURL?.absoluteString ?? "",
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
            switch backend {
            case .openai:
                return try await OpenAIBatchClient(session: session, durationResolver: { _ in duration })
                    .transcribeFile(at: audioURL, apiKey: key, model: identifier, language: language)
            case .cartesia:
                return try await CartesiaBatchClient(session: session)
                    .transcribeFile(at: audioURL, apiKey: key, language: language)
            case .gladia:
                return try await GladiaBatchClient(session: session)
                    .transcribeFile(at: audioURL, apiKey: key, model: identifier, language: language)
            case .speechmatics:
                return try await SpeechmaticsBatchClient(session: session)
                    .transcribeFile(at: audioURL, apiKey: key, model: identifier, language: language)
            }
        } catch {
            // URLSession may report cancellation as URLError.cancelled. Keep
            // cancellation distinct from a failed recording on every route.
            throw BatchTranscriptionJob.mapCancellation(error)
        }
    }

    private enum Backend {
        case openai
        case cartesia
        case gladia
        case speechmatics
    }

    /// One mapping controls discovery, credentials and execution. Model entries
    /// and defaults continue to be owned by the shared catalogue and clients.
    private static func backend(for model: String) -> Backend? {
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
