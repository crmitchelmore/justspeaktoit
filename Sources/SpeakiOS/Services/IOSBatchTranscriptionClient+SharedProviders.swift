#if os(iOS)
import Foundation
import SpeakCore

/// Batch providers whose shared SpeakCore client the iOS app calls directly.
/// The raw values are the catalogue provider IDs in
/// `BatchTranscriptionRouting.iosSharedClientProviderIDs`.
enum IOSSharedBatchProvider: String, CaseIterable, Sendable {
    case assemblyai, deepgram, elevenlabs, groq, mistral, modulate, revai, soniox, speechmatics
}

extension IOSBatchTranscriptionClient {
    /// Endpoint, payload, polling and job clean-up stay in the shared clients,
    /// the same ones Mac and the desktop hosts use.
    func transcribeWithSharedClient(
        _ provider: IOSSharedBatchProvider,
        at url: URL,
        model: String,
        language: String?,
        apiKey: String
    ) async throws -> TranscriptionResult {
        let duration: @Sendable (URL) async -> TimeInterval = { url in
            await resolvedTranscriptionDuration(reported: nil, lastSegmentEnd: nil, audioURL: url)
        }
        let staging = SharedMultipartUploadStaging.posixShared
        let client: any IOSSharedBatchClient
        switch provider {
        case .assemblyai:
            client = AssemblyAIBatchClient(session: session, keywords: keywords, durationResolver: duration)
        case .deepgram:
            client = DeepgramBatchClient(session: session, keywords: keywords, durationResolver: duration)
        case .elevenlabs:
            client = ElevenLabsBatchClient(
                session: session, staging: staging, keywords: keywords, durationResolver: duration
            )
        case .groq:
            client = GroqBatchClient(
                session: session, staging: staging, keywords: keywords, durationResolver: duration
            )
        case .mistral:
            client = MistralBatchClient(
                session: session, multipartStaging: staging, keywords: keywords, durationResolver: duration
            )
        case .modulate:
            client = ModulateBatchClient(session: session, multipartStaging: staging)
        case .revai:
            client = RevAIBatchClient(session: session, multipartStaging: staging, durationResolver: duration)
        case .soniox:
            client = SonioxBatchClient(session: session, keywords: keywords, multipartStaging: staging)
        case .speechmatics:
            client = SpeechmaticsBatchClient(session: session, keywords: keywords)
        }
        do {
            return try await client.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
        } catch {
            throw BatchTranscriptionJob.mapCancellation(error)
        }
    }
}

/// The common file-upload entry point the shared batch clients expose.
protocol IOSSharedBatchClient: Sendable {
    func transcribeFile(at url: URL, apiKey: String, model: String, language: String?) async throws
        -> TranscriptionResult
}

extension AssemblyAIBatchClient: IOSSharedBatchClient {}
extension DeepgramBatchClient: IOSSharedBatchClient {}
extension ElevenLabsBatchClient: IOSSharedBatchClient {}
extension GroqBatchClient: IOSSharedBatchClient {}
extension MistralBatchClient: IOSSharedBatchClient {}
extension ModulateBatchClient: IOSSharedBatchClient {}
extension RevAIBatchClient: IOSSharedBatchClient {}
extension SonioxBatchClient: IOSSharedBatchClient {}
extension SpeechmaticsBatchClient: IOSSharedBatchClient {}
#endif
