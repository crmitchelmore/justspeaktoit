import Foundation
import SpeakCore

// MARK: - Errors

enum ElevenLabsTranscriberError: LocalizedError {
    case missingAPIKey
    case invalidURLComponents
    case connectionFailed
    case invalidAPIKeyOrMissingScribeAccess

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "ElevenLabs API key is missing. Please add it in Settings → ElevenLabs."
        case .invalidURLComponents:
            return "Failed to construct ElevenLabs WebSocket URL."
        case .connectionFailed:
            return "Failed to establish WebSocket connection to ElevenLabs."
        case .invalidAPIKeyOrMissingScribeAccess:
            return "ElevenLabs API key is invalid or does not have speech-to-text (Scribe) access. "
                + "Check your key in Settings → ElevenLabs."
        }
    }
}

/// macOS capture adapter. ElevenLabs transport, framing, segmentation and
/// finalisation live exclusively in SpeakCore and are shared with iOS/Windows.
final class ElevenLabsLiveTranscriber: @unchecked Sendable {
    static let minimumChunkBytes = 3_200
    static let preferredChunkBytes = 3_200

    private let client: any FinalizingStreamingTranscriptionClient
    private let lock = NSLock()
    private var run = ElevenLabsControllerRun()

    // Preserve the exact existing initializer, including a caller-owned session.
    convenience init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
        sampleRate: Int = 16000,
        session: URLSession = .shared
    ) {
        self.init(client: ElevenLabsLiveClient(
            apiKey: apiKey, modelID: modelID, sampleRate: sampleRate, session: session
        ))
    }

    convenience init(
        apiKey: String,
        modelID: String = "scribe_v2_realtime",
        sampleRate: Int = 16000,
        language: String?,
        session: URLSession = .shared
    ) {
        self.init(client: ElevenLabsLiveClient(
            apiKey: apiKey, modelID: modelID, language: language, sampleRate: sampleRate, session: session
        ))
    }

    init(client: any FinalizingStreamingTranscriptionClient) { self.client = client }

    var snapshot: ElevenLabsControllerRun.Snapshot { lock.withLock { run }.snapshot }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        let active = ElevenLabsControllerRun()
        lock.withLock { run.cancel(); run = active }
        client.start(onTranscript: { text, final in
            guard active.record(text: text, final: final) else { return }
            onTranscript(text, final)
        }, onError: { error in
            guard active.record(error: error) else { return }
            onError(error)
        })
    }

    func sendAudio(_ data: Data) { client.sendAudio(data) }

    func finishAndWait() async -> ElevenLabsControllerRun.Snapshot {
        let active = lock.withLock { run }
        let whole = await client.finishAndWait()
        if Task.isCancelled { active.cancel() }
        return active.finish(whole: whole)
    }

    func takeFailureForReporting() -> Error? { lock.withLock { run }.takeFailureForReporting() }

    func stop() {
        lock.withLock { run }.cancel()
        client.stop()
    }
}
