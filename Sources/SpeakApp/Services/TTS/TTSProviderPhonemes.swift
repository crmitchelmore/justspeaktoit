import Foundation
import SpeakCore

// MARK: - TTSProvider Phoneme Capabilities

/// Bridges the app's TTSProvider enum to SpeakCore's provider-agnostic
/// pronunciation processing (see PronunciationManager.generateSSML).
extension TTSProvider: PronunciationPhonemeCapable {
  /// Whether this provider supports SSML phoneme tags.
  var supportsSSMLPhonemes: Bool {
    switch self {
    case .azure, .system: return true
    case .elevenlabs, .openai, .deepgram, .soniox: return false
    }
  }

  /// The phoneme alphabet to use for SSML tags.
  var phonemeAlphabet: String {
    switch self {
    case .azure: return "ipa"
    case .system: return "ipa"
    default: return "ipa"
    }
  }
}
