import Foundation
import os.log
import SpeakCore

// MARK: - Errors

enum SonioxLiveError: LocalizedError {
    case batchNotSupported
    case transcriptionFailed(String)
    case transcriptionTimedOut

    var errorDescription: String? {
        switch self {
        case .batchNotSupported:
            return "Soniox is currently only available for live streaming in Speak."
        case .transcriptionFailed(let message):
            return "Soniox transcription failed: \(message)"
        case .transcriptionTimedOut:
            return "Soniox transcription did not complete in time."
        }
    }
}

// MARK: - Provider

// Soniox v6 supports real-time streaming and asynchronous batch transcription.
struct SonioxTranscriptionProvider: SharedBatchClientProvider {
    let batchClient: SonioxBatchClient

    init(
        session: URLSession = .shared,
        pollingDelay: Duration = .seconds(2),
        maximumPollingAttempts: Int = 90,
        multipartStaging: MultipartUploadStaging = .shared,
        independentCleanup: Bool = false
    ) {
        let logger = SpeakLogger.logger(category: "SonioxTranscriptionProvider")
        let client = SonioxBatchClient(
            session: session, pollingDelay: pollingDelay, maximumPollingAttempts: maximumPollingAttempts,
            multipartStaging: multipartStaging.sharedStore,
            reportCleanupFailure: { message in
                logger.error("Failed to clean up Soniox async resources: \(message, privacy: .public)")
            }
        )
        batchClient = independentCleanup ? client.withIndependentCleanup() : client
    }

    func transcribeFile(
        at url: URL, apiKey: String, model: String, language: String?
    ) async throws -> TranscriptionResult {
        do {
            return try await batchClient.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
        } catch let error as SonioxBatchError {
            switch error {
            case .unsupportedModel: throw SonioxLiveError.batchNotSupported
            case .transcriptionFailed(let message): throw SonioxLiveError.transcriptionFailed(message)
            case .transcriptionTimedOut: throw SonioxLiveError.transcriptionTimedOut
            }
        }
    }

    func supportedModels() -> [ModelCatalog.Option] {
        ModelCatalog.liveTranscriptionOptions(forProvider: metadata.id) + batchClient.supportedModels()
    }
}
