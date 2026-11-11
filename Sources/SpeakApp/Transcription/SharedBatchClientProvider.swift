import AVFoundation
import Foundation
import SpeakCore

/// A macOS provider whose request, response and error contract is a shared
/// SpeakCore batch client. The adapter adds only Apple wiring (native duration
/// probing, upload staging, logging), so these defaults forward everything
/// else unchanged; a provider overrides a member only to translate it.
protocol SharedBatchClientProvider: TranscriptionProvider {
    associatedtype BatchClient: TranscriptionProvider
    var batchClient: BatchClient { get }
}

extension SharedBatchClientProvider {
    var metadata: TranscriptionProviderMetadata { batchClient.metadata }

    func transcribeFile(
        at url: URL, apiKey: String, model: String, language: String?
    ) async throws -> TranscriptionResult {
        try await batchClient.transcribeFile(at: url, apiKey: apiKey, model: model, language: language)
    }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult { await batchClient.validateAPIKey(key) }
    func requiresAPIKey(for model: String) -> Bool { batchClient.requiresAPIKey(for: model) }
    func supportedModels() -> [ModelCatalog.Option] { batchClient.supportedModels() }
}

/// The two ways the Apple adapters measure a recording for a batch client.
enum AppleAudioDuration {
    /// The duration AVFoundation reads from the file; throws when it cannot.
    static let asset: @Sendable (URL) async throws -> TimeInterval = { url in
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// The file's duration, or zero when it cannot be read.
    static let resolved: @Sendable (URL) async -> TimeInterval = { url in
        await resolvedTranscriptionDuration(reported: nil, lastSegmentEnd: nil, audioURL: url)
    }
}
