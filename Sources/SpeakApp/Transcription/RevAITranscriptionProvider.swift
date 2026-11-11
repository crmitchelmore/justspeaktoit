import Foundation
import SpeakCore

/// Keeps native asset duration at the Apple boundary. Requests, polling and
/// response mapping use the same streamed batch client as Windows.
struct RevAITranscriptionProvider: SharedBatchClientProvider {
    let batchClient: RevAIBatchClient

    init(session: URLSession = .shared, multipartStaging: MultipartUploadStaging = .shared) {
        batchClient = RevAIBatchClient(
            session: session, multipartStaging: multipartStaging.sharedStore,
            durationResolver: AppleAudioDuration.asset
        )
    }
}
