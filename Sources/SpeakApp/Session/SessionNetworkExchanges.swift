import Foundation
import SpeakCore

/// The History "network" rows a dictation session records for its
/// transcription and post-processing steps. On-device steps get a `local://`
/// row so History shows which engine ran even when nothing left the Mac.
enum SessionNetworkExchanges {
  private static let openRouterChatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

  /// The row for a finished live (streaming) transcription, or nil for a
  /// cloud provider that does not report one here.
  static func liveTranscription(_ result: TranscriptionResult) -> HistoryNetworkExchange? {
    let duration = String(format: "%.1f", result.duration)
    let headers = ["Model": result.modelIdentifier, "Duration": "\(duration)s"]
    let transcript = "Transcript: \(String(result.text.prefix(500)))"
    if result.modelIdentifier.hasPrefix("local/streaming/") {
      let localURL = URL(string: "local://\(localStreamingRuntime(for: result.modelIdentifier))")!
        .appendingPathComponent(result.modelIdentifier)
      return HistoryNetworkExchange(
        url: localURL,
        method: "On-Device",
        requestHeaders: headers,
        requestBodyPreview: "Local streaming audio (\(duration) seconds)",
        responseCode: 200,
        responseHeaders: [:],
        responseBodyPreview: transcript
      )
    }
    if result.modelIdentifier.contains("deepgram") {
      return HistoryNetworkExchange(
        url: URL(string: "wss://api.deepgram.com/v1/listen")!,
        method: "WebSocket",
        requestHeaders: headers,
        requestBodyPreview: "Streaming audio (\(duration) seconds)",
        responseCode: 200,
        responseHeaders: [:],
        responseBodyPreview: result.rawPayload ?? transcript
      )
    }
    if result.modelIdentifier.contains("apple") {
      return HistoryNetworkExchange(
        url: URL(string: "local://SFSpeechRecognizer")!,
        method: "On-Device",
        requestHeaders: headers,
        requestBodyPreview: "On-device speech recognition (\(duration) seconds)",
        responseCode: 200,
        responseHeaders: [:],
        responseBodyPreview: transcript
      )
    }
    return nil
  }

  /// The row for a transcribed audio file: on-device for a local model, the
  /// OpenRouter request when a batch provider returned its raw payload.
  static func fileTranscription(
    _ result: TranscriptionResult,
    fileName: String,
    isLocal: Bool
  ) -> HistoryNetworkExchange? {
    if isLocal {
      return HistoryNetworkExchange(
        url: URL(string: "local://whisperkit")!,
        method: "On-Device",
        requestHeaders: [
          "Model": result.modelIdentifier,
          "Duration": String(format: "%.1fs", result.duration)
        ],
        requestBodyPreview: "Local audio file: \(fileName)",
        responseCode: 200,
        responseHeaders: [:],
        responseBodyPreview: "Transcript: \(String(result.text.prefix(500)))"
      )
    }
    guard let payload = result.rawPayload else { return nil }
    return HistoryNetworkExchange(
      url: openRouterChatURL,
      method: "POST",
      requestHeaders: [
        "Model": result.modelIdentifier,
        "Content-Type": "application/json"
      ],
      requestBodyPreview: "JSON payload with \(fileName) audio",
      responseCode: 200,
      responseHeaders: [:],
      responseBodyPreview: String(payload.prefix(800))
    )
  }

  /// The OpenRouter row for a post-processing response that carried its payload.
  static func postProcessing(model: String, requestPreview: String, payload: String) -> HistoryNetworkExchange {
    HistoryNetworkExchange(
      url: openRouterChatURL,
      method: "POST",
      requestHeaders: ["Model": model],
      requestBodyPreview: requestPreview,
      responseCode: 200,
      responseHeaders: [:],
      responseBodyPreview: String(payload.prefix(800))
    )
  }

  static func localStreamingRuntime(for modelIdentifier: String) -> String {
    if FluidAudioParakeetModel.matches(modelIdentifier) {
      return "fluidaudio"
    }
    if WhisperKitStreamingModel.matches(modelIdentifier) {
      return "whisperkit"
    }
    #if APP_STORE
    return "unknown-local"
    #else
    return "sherpa-onnx"
    #endif
  }
}
