import Foundation
import SpeakCore

// MARK: - Errors

public enum OpenAIRealtimeError: LocalizedError, Sendable {
    case missingAPIKey
    case preReadyAudioOverflow
    case connectionFailed(String)
    case sessionError(String)

    public var errorDescription: String? {
        switch self {
        case .preReadyAudioOverflow:
            return "Recording stopped because OpenAI startup took too long. Some audio was not sent; "
                + "the transcript may be incomplete."
        case .missingAPIKey:
            return "OpenAI API key is not configured."
        case .connectionFailed(let message):
            return "OpenAI Realtime connection failed: \(message)"
        case .sessionError(let message):
            return "OpenAI Realtime session error: \(message)"
        }
    }
}

// MARK: - WebSocket client

/// Thin iOS adapter over the shared `OpenAIRealtimeLiveClient`.
///
/// The transcriber keeps its established surface (per-item events, readiness
/// and pending-send waits, commit, immediate stop) while endpoint, GA
/// `session.update`, bounded admission and finalisation are shared with macOS
/// and Windows. The shared overflow failure is mapped onto
/// `preReadyAudioOverflow`, which the session owner treats as the end of capture.
final class OpenAIRealtimeWebSocketClient: @unchecked Sendable {
    typealias Event = OpenAIRealtimeLiveClient.Event

    private let client: OpenAIRealtimeLiveClient

    init(
        apiKey: String, model: String, language: String?, sampleRate: Int,
        makeConnection: OpenAIRealtimeLiveClient.ConnectionFactory? = nil
    ) {
        if let makeConnection {
            client = OpenAIRealtimeLiveClient(
                apiKey: apiKey, model: model, language: language, prompt: nil, sampleRate: sampleRate,
                makeConnection: makeConnection
            )
        } else {
            client = OpenAIRealtimeLiveClient(
                apiKey: apiKey, model: model, language: language, prompt: nil, sampleRate: sampleRate
            )
        }
    }

    func start(onEvent: @escaping (Event) -> Void, onError: @escaping (Error) -> Void) {
        client.start(onEvent: onEvent, onError: { onError(Self.platformError($0)) })
    }

    /// Closes immediately; the transcriber sequences commit and completion itself.
    func stop() { client.cancel() }

    func sendAudio(_ pcmData: Data) { client.sendAudio(pcmData) }

    /// PCM admitted but not yet handed to the transport.
    var bufferedAudioBytes: Int { client.queuedAudioByteCount }

    func commitInputBuffer() { client.commitInputBuffer() }

    func waitForPendingSends() async { await client.awaitPendingSends(timeout: 1.5) }

    func awaitSessionReady(timeout: TimeInterval) async -> Bool {
        await client.awaitSessionReady(timeout: timeout)
    }

    /// Shared graceful finalisation for callers that want the client to
    /// drain, commit and wait for the committed item's transcript.
    func finishAndWait() async -> String? { await client.finishAndWait() }

    private static func platformError(_ error: Error) -> Error {
        if case OpenAIRealtimeStreamingError.audioOverflow = error { return OpenAIRealtimeError.preReadyAudioOverflow }
        return error
    }
}
