import Foundation
import SpeakCore

/// Keeps native duration loading on Apple while using the same
/// file-transcription request and result code as the Windows host. Live
/// Deepgram runs on `SharedClientLiveController` with `DeepgramLiveClient`.
struct DeepgramTranscriptionProvider: SharedBatchClientProvider {
    let batchClient: DeepgramBatchClient

    init(session: URLSession = .shared) {
        batchClient = DeepgramBatchClient(session: session, durationResolver: AppleAudioDuration.asset)
    }
}
