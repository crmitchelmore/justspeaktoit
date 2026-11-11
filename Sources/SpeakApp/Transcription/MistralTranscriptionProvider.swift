import Foundation
import SpeakCore

/// The batch transport is shared; native asset duration and OS logging remain
/// in the Apple adapters. Existing call sites and test seams are preserved.
struct MistralTranscriptionProvider: SharedBatchClientProvider {
    let batchClient: MistralBatchClient

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.mistral.ai/v1")!,
        multipartStaging: MultipartUploadStaging = .shared
    ) {
        batchClient = MistralBatchClient(
            session: session, baseURL: baseURL, multipartStaging: multipartStaging.sharedStore,
            durationResolver: AppleAudioDuration.resolved
        )
    }

    nonisolated static func makeMultipartUploadBody(
        sourceURL: URL, staging: MultipartUploadStaging, boundary: String, model: String, language: String?
    ) throws -> URL {
        try MistralBatchClient.makeMultipartUploadBody(
            sourceURL: sourceURL, staging: staging.sharedStore, boundary: boundary, model: model, language: language
        )
    }
}
