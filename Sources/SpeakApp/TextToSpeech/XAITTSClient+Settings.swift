import Foundation
import SpeakCore

/// How Speak's settings map onto an xAI speech request.
///
/// Pure translation — request shape, codec choice, the controls xAI cannot
/// honour and the price — kept beside the client so the client itself is only
/// transport, files and playback.
extension XAITTSClient {
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
}
