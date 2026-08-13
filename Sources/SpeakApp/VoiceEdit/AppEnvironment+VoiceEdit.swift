import Foundation

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
        appSettings: settings,
        historyManager: history
      )
    )
  }

  /// Global-shortcut entry point for voice edit mode.
  func toggleVoiceEdit() {
    installVoiceEdit()
    voiceEdit?.toggle()
  }
}
