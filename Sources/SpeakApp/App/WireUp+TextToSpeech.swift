import Foundation
import SpeakCore

/// Text-to-speech assembly: one client per provider behind TextToSpeechManager.
extension WireUp {
  static func buildTTSManager(
    settings: AppSettings,
    secureStorage: SecureAppStorage,
    pronunciation: PronunciationManager,
    defaults: UserDefaults
  ) -> TextToSpeechManager {
    let clients: [TTSProvider: TextToSpeechClient] = [
      .elevenlabs: ElevenLabsClient(secureStorage: secureStorage),
      .openai: OpenAITTSClient(secureStorage: secureStorage),
      .openrouter: OpenRouterTTSClient(secureStorage: secureStorage),
      .azure: AzureSpeechClient(secureStorage: secureStorage, appSettings: settings),
      .deepgram: DeepgramTTSClient(secureStorage: secureStorage),
      .soniox: SonioxTTSClient(secureStorage: secureStorage, appSettings: settings),
      .cartesia: CartesiaTTSClient(secureStorage: secureStorage),
      .groq: GroqTTSClient(secureStorage: secureStorage),
      .gemini: GeminiTTSClient(secureStorage: secureStorage),
      .mistral: MistralTTSClient(secureStorage: secureStorage),
      .speechmatics: SpeechmaticsTTSClient(secureStorage: secureStorage),
      .xai: XAITTSClient(secureStorage: secureStorage),
      .system: SystemTTSClient()
    ]
    return TextToSpeechManager(
      appSettings: settings,
      secureStorage: secureStorage,
      clients: clients,
      pronunciationManager: pronunciation,
      defaults: defaults
    )
  }
}
