import Foundation
import SpeakCore

// MARK: - OpenAI Realtime Live Transcriber

/// Thin macOS adapter over the shared `OpenAIRealtimeLiveClient`.
///
/// Endpoint, GA `session.update`, bounded PCM admission, readiness gating and
/// commit sequencing live in SpeakCore and are shared with iOS and Windows.
/// This wrapper keeps the controller's established call sequence: wait for
/// readiness, drain pending sends, commit, wait for the completed event, then
/// close immediately with `stop()`. `finishAndWait()` exposes the shared
/// graceful path for callers that want the client to sequence all of that.
final class OpenAIRealtimeLiveTranscriber: @unchecked Sendable {
  typealias Event = OpenAIRealtimeLiveClient.Event

  private let client: OpenAIRealtimeLiveClient

  init(
    apiKey: String,
    model: String,
    language: String?,
    prompt: String?,
    sampleRate: Int = OpenAIRealtimeProtocol.sampleRate,
    session: URLSession? = nil
  ) {
    client = OpenAIRealtimeLiveClient(
      apiKey: apiKey,
      model: model,
      language: language,
      prompt: prompt,
      sampleRate: sampleRate,
      session: session
    )
  }

  // MARK: - Lifecycle

  func start(
    onEvent: @escaping (Event) -> Void,
    onError: @escaping (Error) -> Void
  ) {
    client.start(onEvent: onEvent, onError: onError)
  }

  /// Synchronous bounded admission; audio captured before the configuration
  /// acknowledgement waits in the shared queue instead of being dropped.
  func sendAudio(_ pcm16Data: Data) {
    client.sendAudio(pcm16Data)
  }

  /// Queues `input_audio_buffer.commit` behind the admitted audio. Nothing is
  /// sent for an empty recording, so the server never reports an empty commit.
  func commitInputBuffer() {
    client.commitInputBuffer()
  }

  /// Resolves once `session.updated` acknowledged our configuration, or
  /// `false` at the timeout so a quick stop-after-start stays bounded.
  func awaitSessionReady(timeout: TimeInterval) async -> Bool {
    await client.awaitSessionReady(timeout: timeout)
  }

  /// Closes the socket immediately. The controller has already sequenced the
  /// commit and its bounded completion wait, matching the previous behaviour.
  func stop() {
    client.cancel()
  }

  func waitForPendingSends(timeout: TimeInterval = 1.5) async {
    await client.awaitPendingSends(timeout: timeout)
  }

  /// Shared graceful finalisation: drains, commits, waits for the committed
  /// item's transcript within the model's finalise budget, then closes.
  func finishAndWait() async -> String? {
    await client.finishAndWait()
  }
}

// MARK: - Errors

/// Controller-level failures. Transport, admission and server errors now come
/// from `OpenAIRealtimeStreamingError` in SpeakCore.
enum OpenAIRealtimeError: LocalizedError {
  case missingAPIKey
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "OpenAI API key is missing. Add it in Settings → Models / Keys."
    case .encodingFailed:
      return "Failed to encode OpenAI Realtime payload"
    }
  }
}

// MARK: - Provider (factory)

/// Lightweight factory for `OpenAIRealtimeLiveTranscriber`. Unlike the
/// AssemblyAI / ElevenLabs / OpenAI batch providers, this isn't a
/// `TranscriptionProvider` because it doesn't expose a batch transcription
/// path — `OpenAITranscriptionProvider` already covers Whisper batch.
struct OpenAIRealtimeTranscriptionProvider {
  func createLiveTranscriber(
    apiKey: String,
    model: String,
    language: String?,
    prompt: String?,
    sampleRate: Int = OpenAIRealtimeProtocol.sampleRate,
    session: URLSession? = nil
  ) -> OpenAIRealtimeLiveTranscriber {
    OpenAIRealtimeLiveTranscriber(
      apiKey: apiKey,
      model: model,
      language: language,
      prompt: prompt,
      sampleRate: sampleRate,
      session: session
    )
  }

  /// Translates an `openai/...-streaming` model id into the bare model name
  /// expected by the Realtime API.
  static func realtimeModelName(from catalogID: String) -> String {
    OpenAITranscriptionModels.apiModelName(from: catalogID)
  }
}
