import Foundation
import SpeakCore

/// "Send to Mac": the local listener that receives transcripts from iOS.
extension WireUp {
  static func configureSendToMac(environment: AppEnvironment, settings: AppSettings) {
    guard SendToMacAvailability.isAvailable else { return }
    let transportServer = environment.transportServer
    let permissions = environment.permissions
    // A finished transcript from a paired phone or tablet is pasted where the
    // cursor is, like a Handoff continuation. The live inserter only accepts
    // text during a Mac recording, so routing it there dropped every send.
    transportServer.onTranscriptReceived = { _, text in
      Task { @MainActor in
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = SmartTextOutput(permissionsManager: permissions, appSettings: settings)
          .output(text: text, target: nil)
      }
    }

    // The listener can also fail asynchronously, after start() has already returned
    // (NWListener.start is non-throwing). Handle that the same way as a synchronous
    // failure so the toggle never stays ON with a dead listener behind it — this covers
    // both the launch-time start below and the one in Settings, which share this server.
    transportServer.onFailure = { error in
      Task { @MainActor in
        SpeakLogger.logError(error, context: "Send to Mac listener failed", logger: SpeakLogger.transport)
        settings.enableSendToMac = false
      }
    }

    if settings.enableSendToMac {
      do {
        try transportServer.start()
      } catch {
        // Keep the stored preference honest: leaving the toggle ON while the
        // listener never started would silently drop every "Send to Mac" session.
        SpeakLogger.logError(error, context: "Send to Mac startup", logger: SpeakLogger.transport)
        settings.enableSendToMac = false
      }
    }
  }
}
