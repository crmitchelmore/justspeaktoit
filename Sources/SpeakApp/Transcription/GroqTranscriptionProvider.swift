import Foundation
import SpeakCore

/// The Groq endpoint, catalogue and request contract are shared by all desktops.
struct GroqTranscriptionProvider: SharedBatchClientProvider {
    let batchClient: GroqBatchClient

    init(session: URLSession = .shared) {
        batchClient = GroqBatchClient(session: session, durationResolver: AppleAudioDuration.resolved)
    }
}
