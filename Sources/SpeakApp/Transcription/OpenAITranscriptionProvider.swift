import Foundation
import SpeakCore

/// Native duration probing stays on Apple; request and response semantics are
/// shared with the Windows app through SpeakCore.
struct OpenAITranscriptionProvider: SharedBatchClientProvider {
    let batchClient: OpenAIBatchClient

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        validationServiceName: String = "OpenAI"
    ) {
        batchClient = OpenAIBatchClient(
            session: session,
            baseURL: baseURL,
            validationServiceName: validationServiceName,
            durationResolver: AppleAudioDuration.resolved
        )
    }
}
