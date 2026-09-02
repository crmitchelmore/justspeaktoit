import Foundation
import SpeakCore

// MARK: - TTSProvider Cost Estimates

/// Pre-synthesis cost estimates, kept beside the provider enum so published
/// rate changes are a one-file edit rather than a hunt through the manager.
extension TTSProvider {
  /// Estimated spend for `characterCount` characters, or `nil` when synthesis
  /// is free. `quality` only affects providers that price per model tier.
  func estimatedCost(characterCount: Int, quality: TTSQuality) -> Decimal? {
    guard let rate = costPerThousandCharacters(quality: quality) else { return nil }
    return Decimal(characterCount) * rate / 1000
  }

  private func costPerThousandCharacters(quality: TTSQuality) -> Decimal? {
    switch self {
    case .elevenlabs:
      // ~$0.30 per 1000 characters on the standard plan.
      return Decimal(string: "0.30")
    case .openai:
      // gpt-4o-mini-tts / tts-1 / tts-1-hd, priced per 1M characters.
      switch quality {
      case .standard: return Decimal(string: "0.0006")
      case .high: return Decimal(string: "0.015")
      case .highest: return Decimal(string: "0.030")
      }
    case .azure:
      // ~$16 per 1M characters for neural voices.
      return Decimal(string: "0.016")
    case .deepgram:
      return DeepgramTTSAPI.costPerThousandCharacters
    case .soniox:
      // Billed per token (~$0.70 per hour of generated speech); the shared API
      // exposes the equivalent character estimate.
      return SonioxTTSAPI.estimatedCostPerThousandCharacters
    case .cartesia:
      // Billed one credit per character; the shared API exposes the plan rate
      // as a character estimate.
      return CartesiaTTSAPI.estimatedCostPerThousandCharacters
    case .system:
      return nil
    }
  }
}
