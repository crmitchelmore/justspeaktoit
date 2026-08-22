import Foundation
import SpeakCore

extension AppEnvironment {
  /// Creates the voice-edit controller ("select text → hotkey → speak an instruction →
  /// selection replaced with the LLM rewrite"). Idempotent, mirrors the other install methods.
  func installVoiceEdit() {
    guard voiceEdit == nil else { return }
    voiceEdit = VoiceEditController(
      mainManager: main,
      audioFileManager: audio,
      transcriptionManager: transcription,
      rewriter: VoiceEditRewriter(client: openRouter, settings: settings),
      hudManager: hud,
      hotKeyManager: hotKeys,
      selectionService: VoiceEditSelectionService(
        permissionsManager: permissions,
        insertionRecords: main.insertionRecords
      ),
      replacementService: VoiceEditReplacementService(permissionsManager: permissions)
    )
  }

  /// Global-shortcut entry point for voice edit mode. Inert on channels that
  /// cannot read or replace another app's selection; the shortcut is not
  /// registered there either, so this is the last line of defence.
  func toggleVoiceEdit() {
    guard DistributionChannel.current.supportsVoiceEdit else { return }
    installVoiceEdit()
    voiceEdit?.toggle()
  }
}
