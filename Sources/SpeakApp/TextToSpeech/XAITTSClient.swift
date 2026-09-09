import AVFoundation
import Foundation
import SpeakCore

/// xAI text-to-speech client.
///
/// HTTP transport lives in `SpeakCore.XAITTSAPI`, the WebSocket protocol in
/// `SpeakCore.XAITTSRealtime` and the voice list in `SpeakCore.XAITTSCatalog`;
/// this wrapper adds keychain lookup, file handling, cost tracking and the
/// progressive-playback path. One xAI key covers transcription and speech
/// generation, so a user who already dictates with xAI gets voices with no
/// extra setup.
///
/// xAI documents no pitch parameter, so a non-default pitch is reported rather
/// than silently dropped. Speaking rate is supported, but only between 0.7 and
/// 1.5, so a request outside that range is reported too instead of being
/// clamped into a speed the user did not choose.
actor XAITTSClient: TextToSpeechClient, ProgressiveTextToSpeechClient {
  let provider: TTSProvider = .xai
  /// Progressive playback runs the socket in PCM, so the samples can be
  /// scheduled as they arrive; the default 24 kHz is what xAI generates.
  let progressiveSampleRate = XAITTSAPI.defaultSampleRate

  private let api: XAITTSAPI
  private let secureStorage: SecureAppStorage
  private let session: URLSession

  init(secureStorage: SecureAppStorage, session: URLSession = .shared) {
    self.secureStorage = secureStorage
    self.session = session
    self.api = XAITTSAPI(session: session)
  }

  // MARK: - Batch synthesis

  func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
    let apiKey = try await requireAPIKey()
    try Self.validate(settings: settings)
    let codec = Self.codec(for: settings.format)
    let request = Self.makeRequest(voice: voice, settings: settings, codec: codec)

    // One request accepts 15,000 characters. Longer input becomes a sequence of
    // requests split at sentence ends, and the parts are joined into the single
    // file the caller expects.
    let segments = TTSTextChunker.chunks(text, maximumCharacters: XAITTSAPI.maximumTextCharacters)
    guard !segments.isEmpty else {
      throw TTSError.synthesisFailure("There is no text to speak")
    }

    let format = Self.audioFormat(for: codec)
    var partURLs: [URL] = []
    do {
      for segment in segments {
        let data = try await api.synthesize(text: segment, apiKey: apiKey, request: request)
        partURLs.append(try saveAudio(data, format: format))
      }
    } catch let error as XAITTSAPIError {
      TTSAudioJoiner.discard(partURLs)
      throw Self.ttsError(for: error)
    } catch {
      TTSAudioJoiner.discard(partURLs)
      throw error
    }

    let outputURL = try TTSAudioJoiner.join(partURLs, format: format)
    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: request.voiceID,
      duration: try await Self.duration(of: outputURL),
      characterCount: text.count,
      cost: Self.cost(characterCount: text.count)
    )
  }

  // MARK: - Progressive synthesis

  /// Streams one utterance over `wss://api.x.ai/v1/tts`, handing each
  /// `audio.delta` to `onAudioChunk` as it arrives and keeping the samples so
  /// the finished file is identical to what the batch path would produce.
  func synthesizeProgressively(
    text: String,
    voice: String,
    settings: TTSSettings,
    onAudioChunk: @escaping @Sendable (Data) -> Void
  ) async throws -> TTSResult {
    let apiKey = try await requireAPIKey()
    try Self.validate(settings: settings)
    let request = Self.makeRequest(
      voice: voice,
      settings: settings,
      codec: .pcm,
      sampleRate: progressiveSampleRate
    )
    let chunks = TTSTextChunker.chunks(text, maximumCharacters: XAITTSRealtime.textChunkCharacters)
    guard !chunks.isEmpty else {
      throw TTSError.synthesisFailure("There is no text to speak")
    }
    guard let url = XAITTSRealtime.webSocketURL(request: request) else {
      throw TTSError.synthesisFailure("Could not build the xAI speech stream URL")
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let task = session.webSocketTask(with: urlRequest)
    task.resume()

    let pcm: Data
    do {
      pcm = try await Self.stream(chunks: chunks, on: task, onAudioChunk: onAudioChunk)
    } catch {
      // A cancelled utterance is a barge-in: tell xAI to drop the queued audio
      // rather than paying for speech nobody will hear.
      try? await task.send(.string(XAITTSRealtime.textClearJSON))
      task.cancel(with: .goingAway, reason: nil)
      throw error
    }
    task.cancel(with: .normalClosure, reason: nil)

    guard !pcm.isEmpty else {
      throw TTSError.synthesisFailure("xAI produced no audio for this text")
    }
    let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: progressiveSampleRate)
    let outputURL = try saveAudio(wav, format: .wav)
    return TTSResult(
      audioURL: outputURL,
      provider: provider,
      voice: request.voiceID,
      duration: try await Self.duration(of: outputURL),
      characterCount: text.count,
      cost: Self.cost(characterCount: text.count)
    )
  }

  /// Pushes the text and collects audio until `audio.done`.
  ///
  /// Runs on the actor's executor rather than as a detached task so a cancelled
  /// caller stops the loop at the next `checkCancellation`.
  private static func stream(
    chunks: [String],
    on task: URLSessionWebSocketTask,
    onAudioChunk: @escaping @Sendable (Data) -> Void
  ) async throws -> Data {
    for chunk in chunks {
      try Task.checkCancellation()
      guard let frame = XAITTSRealtime.textDeltaJSON(chunk) else {
        throw TTSError.synthesisFailure("Could not encode the xAI speech request")
      }
      try await task.send(.string(frame))
    }
    try await task.send(.string(XAITTSRealtime.textDoneJSON))

    var pcm = Data()
    while true {
      try Task.checkCancellation()
      // An unrecognised frame is ignored rather than fatal: a heartbeat or a
      // field added upstream must not end an utterance mid-sentence.
      guard let event = Self.event(from: try await task.receive()) else { continue }
      switch event {
      case .audio(let audio):
        pcm.append(audio)
        onAudioChunk(audio)
      case .done:
        return pcm
      case .cleared:
        throw CancellationError()
      case .sessionUpdated:
        continue
      case .failure(let message):
        throw TTSError.synthesisFailure("xAI speech stream failed: \(message)")
      }
    }
  }

  private static func event(
    from message: URLSessionWebSocketTask.Message
  ) -> XAITTSRealtimeEvent? {
    switch message {
    case .data(let value): XAITTSRealtimeEvent(frame: value)
    case .string(let value): XAITTSRealtimeEvent(frame: Data(value.utf8))
    @unknown default: nil
    }
  }

  // MARK: - Voices and credentials

  /// The two documented presets plus whatever the account itself lists. xAI
  /// hosts more voices than the capability page names, and the listing is the
  /// only published source for them.
  func listVoices() async throws -> [TTSVoice] {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      return VoiceCatalog.xaiVoices
    }
    guard let accountVoices = try? await api.listVoices(apiKey: apiKey) else {
      return VoiceCatalog.xaiVoices
    }
    let presetIDs = Set(XAITTSCatalog.voices.map(\.id))
    return VoiceCatalog.xaiVoices
      + accountVoices
      .filter { !presetIDs.contains($0.id) }
      .map { voice in
        TTSVoice(
          id: voice.providerVoiceID,
          name: voice.displayName,
          provider: .xai,
          traits: [.neutral, .multilingual],
          previewURL: nil
        )
      }
  }

  func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    await api.validateAPIKey(key)
  }

  // MARK: - Private helpers

  private func requireAPIKey() async throws -> String {
    guard let apiKey = try? await secureStorage.secret(identifier: provider.apiKeyIdentifier),
      !apiKey.isEmpty
    else {
      throw TTSError.apiKeyMissing(provider)
    }
    return apiKey
  }

  static func makeRequest(
    voice: String,
    settings: TTSSettings,
    codec: XAITTSCodec,
    sampleRate: Int = XAITTSAPI.defaultSampleRate
  ) -> XAITTSRequest {
    XAITTSRequest(
      voiceID: voice,
      language: settings.language,
      codec: codec,
      sampleRate: sampleRate,
      speed: settings.speed
    )
  }

  /// xAI serves MP3, WAV and PCM. AAC is not one of them, so an M4A preference
  /// becomes MP3 — the closest compressed container it does serve.
  static func codec(for format: AudioFormat) -> XAITTSCodec {
    switch format {
    case .mp3, .m4a: .mp3
    case .wav: .wav
    }
  }

  static func audioFormat(for codec: XAITTSCodec) -> AudioFormat {
    switch codec {
    case .mp3: .mp3
    case .wav, .pcm: .wav
    }
  }

  /// Reports the controls xAI cannot honour instead of pretending they applied.
  static func validate(settings: TTSSettings) throws {
    if abs(settings.pitch) > 0.001 {
      throw TTSError.synthesisFailure(
        "xAI voices do not support pitch control. Reset it to the default, "
          + "or choose another provider."
      )
    }
    guard XAITTSAPI.speedRange.contains(settings.speed) else {
      throw TTSError.synthesisFailure(
        "xAI accepts a speaking rate between \(XAITTSAPI.speedRange.lowerBound) and "
          + "\(XAITTSAPI.speedRange.upperBound); this one is \(settings.speed)."
      )
    }
  }

  static func cost(characterCount: Int) -> Decimal {
    Decimal(characterCount) * XAITTSAPI.estimatedCostPerThousandCharacters / 1000
  }

  static func ttsError(for error: XAITTSAPIError) -> TTSError {
    switch error {
    case .invalidResponse:
      return .synthesisFailure("Invalid response")
    case .emptyText:
      return .synthesisFailure("There is no text to speak")
    case .textTooLong(let limit, let characterCount):
      return .synthesisFailure(
        "xAI accepts up to \(limit) characters per request (this text is \(characterCount))"
      )
    case .unauthorized:
      // The status code is the deciding signal: a revoked key must point the
      // user at Settings rather than at a generic synthesis failure.
      return .apiKeyMissing(.xai)
    case .quotaExceeded(let message):
      // A stored key is not credit, so this is reported as an account state to
      // fix in the console rather than as a bad key.
      return .providerAccessRequired(
        .xai,
        reason: "no credit remaining at console.x.ai (\(message))"
      )
    case .voiceNotFound(let message):
      return .invalidVoice(message)
    case .rateLimited(let message):
      return .synthesisFailure("xAI rate limit reached: \(message)")
    case .badRequest(let message):
      return .synthesisFailure("xAI rejected the request: \(message)")
    case .httpError(let statusCode, let message):
      return .synthesisFailure("HTTP \(statusCode): \(message)")
    }
  }

  private func saveAudio(_ data: Data, format: AudioFormat) throws -> URL {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("tts_\(UUID().uuidString).\(format.fileExtension)")
    try data.write(to: fileURL)
    return fileURL
  }

  private static func duration(of url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    return CMTimeGetSeconds(try await asset.load(.duration))
  }
}
