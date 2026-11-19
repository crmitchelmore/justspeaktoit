import Foundation
import SpeakCore

/// Native duration probing stays on Apple; the Scribe request and response
/// contract is shared with the Windows host.
struct ElevenLabsTranscriptionProvider: SharedBatchClientProvider {
    let batchClient: ElevenLabsBatchClient

    init(session: URLSession = .shared) {
        batchClient = ElevenLabsBatchClient(session: session, durationResolver: AppleAudioDuration.asset)
    }
}
