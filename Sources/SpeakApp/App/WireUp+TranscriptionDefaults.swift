import Foundation
import SpeakCore

private let logger = SpeakLogger.logger(category: "WireUp")

extension WireUp {
  /// Configure the default live transcription model based on available API keys.
  /// Priority: Deepgram > Apple (fallback)
  /// Called on app launch and after onboarding completes.
  static func configureDefaultTranscriptionProvider(
    settings: AppSettings,
    secureStorage: SecureAppStorage
  ) async {
    // Only configure if the user has never chosen a live transcription model.
    // Checking the stored choice (rather than "is it still Apple?") means a
    // deliberate Apple Speech selection survives every launch.
    guard !settings.hasExplicitLiveTranscriptionModelChoice else {
      logger.info("User has chosen a transcription model, skipping auto-config")
      return
    }

    // Check for Deepgram API key
    let hasDeepgramKey = await secureStorage.hasSecret(identifier: "deepgram.apiKey")

    if hasDeepgramKey {
      await MainActor.run {
        // Re-check after the keychain await: the user may have chosen a model
        // while this task was suspended, and that choice must win.
        guard !settings.hasExplicitLiveTranscriptionModelChoice else {
          logger.info("User chose a transcription model during auto-config, skipping")
          return
        }
        settings.liveTranscriptionModel = "deepgram/nova-3-streaming"
        logger.info("Deepgram API key found, setting as default transcription provider")
      }
    } else {
      logger.info("No Deepgram API key found, using Apple on-device transcription as default")
    }
  }
}
