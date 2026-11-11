import Foundation
import SpeakCore

// MARK: - Automation

extension AppEnvironment {
  /// Opens the local automation socket when the user has opted in.
  ///
  /// Off by default: the socket lets any process running as this user start the
  /// microphone and read past transcripts, so it stays closed until asked for.
  /// Best-effort at launch — a socket that cannot bind puts the preference back
  /// to off rather than failing startup, exactly as "Send to Mac" does.
  func startAutomationServerIfEnabled() {
    guard settings.enableAutomationServer else { return }
    do {
      try startAutomationServer()
    } catch {
      SpeakLogger.logError(error, context: "Automation socket startup", logger: SpeakLogger.transport)
      settings.enableAutomationServer = false
    }
  }

  /// Opens the socket, wiring it onto the same managers the UI drives.
  ///
  /// Throws rather than logging so the Settings toggle can put the stored
  /// preference back in step with reality.
  func startAutomationServer() throws {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    try automationServer.start(
      handler: AppAutomationHandler(
        main: main,
        history: history,
        transcription: transcription,
        tts: tts,
        appVersion: version ?? "unknown"
      )
    )
  }

  /// Closes the socket, so nothing local can drive dictation once the user
  /// turns automation off.
  func stopAutomationServer() {
    automationServer.stop()
  }
}
