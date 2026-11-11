import AppKit
import Foundation
import SpeakCore

/// Global keyboard shortcuts: recording, text-to-speech, navigation, quick
/// voices and pasting the last transcript.
extension AppEnvironment {
  func configureShortcutHandlers() {
    shortcuts.register(action: .startStopRecording) { [weak self] in
      self?.main.toggleRecordingFromUI()
    }
    shortcuts.register(action: .speakClipboard) { [weak self] in
      guard let self else { return }
      if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
        Task {
          try? await self.tts.synthesize(text: text)
        }
      }
    }
    shortcuts.register(action: .speakSelectedText) { [weak self] in
      guard let self else { return }
      // Get selected text via accessibility or pasteboard simulation
      Task {
        if let text = await self.getSelectedText(), !text.isEmpty {
          _ = try? await self.tts.synthesize(text: text)
        }
      }
    }
    shortcuts.register(action: .pauseResumeTTS) { [weak self] in
      guard let self else { return }
      if self.tts.isPlaying {
        self.tts.pause()
      } else {
        self.tts.resume()
      }
    }
    shortcuts.register(action: .stopTTS) { [weak self] in
      self?.tts.stop()
    }
    shortcuts.register(action: .pasteLastHistoryItem) { [weak self] in self?.pasteLastHistoryItem() }
    shortcuts.register(action: .editSelectionByVoice) { [weak self] in self?.toggleVoiceEdit() }
    registerNavigationShortcutHandlers()
    registerQuickVoiceShortcutHandlers()
    #if DEBUG
    if CoreJourneyLaunchProfile.isRequested { return }
    #endif
    shortcuts.startMonitoring()
  }

  private func registerNavigationShortcutHandlers() {
    let navigationActions: [ShortcutAction: SidebarItem] = [
      .openDashboard: .dashboard,
      .showHistory: .history,
      .openVoiceOutput: .voiceOutput,
      .openCorrections: .corrections,
      .openTroubleshooting: .troubleshooting,
      .openSettings: .settings(.general),
      .openTranscriptionSettings: .settings(.transcription),
      .openPostProcessingSettings: .settings(.postProcessing),
      .openDataMigrationSettings: .settings(.dataMigration),
      .openProfilesSettings: .settings(.profiles),
      .openVoiceOutputSettings: .settings(.voiceOutput),
      .openPronunciationSettings: .settings(.pronunciation),
      .openAPIKeysSettings: .settings(.apiKeys),
      .openKeyboardSettings: .settings(.shortcuts),
      .openPermissionsSettings: .settings(.permissions),
      .openCompareModelsSettings: .settings(.compareModels),
      .openAboutSettings: .settings(.about)
    ]
    for (action, item) in navigationActions {
      shortcuts.register(action: action) { [weak self] in
        self?.sidebarNavigationTarget = item
      }
    }
  }

  private func registerQuickVoiceShortcutHandlers() {
    shortcuts.register(action: .quickVoice1) { [weak self] in
      self?.switchToQuickVoice(1)
    }
    shortcuts.register(action: .quickVoice2) { [weak self] in
      self?.switchToQuickVoice(2)
    }
    shortcuts.register(action: .quickVoice3) { [weak self] in
      self?.switchToQuickVoice(3)
    }
  }

  private func getSelectedText() async -> String? {
    // Save current clipboard
    let pasteboard = NSPasteboard.general
    let savedContents = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
      var dict: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) {
          dict[type] = data
        }
      }
      return dict.isEmpty ? nil : dict
    }

    // Simulate Cmd+C to copy selected text
    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
    keyDown?.flags = .maskCommand
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)

    // Wait for clipboard to update
    try? await Task.sleep(nanoseconds: 100_000_000)

    let selectedText = pasteboard.string(forType: .string)

    // Restore clipboard
    pasteboard.clearContents()
    if let savedContents {
      for itemData in savedContents {
        let item = NSPasteboardItem()
        for (type, data) in itemData {
          item.setData(data, forType: type)
        }
        pasteboard.writeObjects([item])
      }
    }

    return selectedText
  }

  private func switchToQuickVoice(_ index: Int) {
    let favorites = settings.ttsFavoriteVoices
    let arrayIndex = index - 1
    if arrayIndex < favorites.count {
      settings.defaultTTSVoice = favorites[arrayIndex]
    }
  }

  /// Pastes the most recent history item's text into the frontmost app,
  /// preferring the post-processed transcription over the raw one. Reuses the
  /// same insertion path as transcription delivery (accessibility or paste,
  /// per the user's configured output method).
  func pasteLastHistoryItem() {
    let text = history.items.first.flatMap { $0.postProcessedTranscription ?? $0.rawTranscription }
    guard let text, PasteTextOutput.hasDeliverableText(text) else {
      hud.finishFailure(
        headline: "Nothing to paste",
        message: "No history items with text yet.",
        displayDuration: 2.5
      )
      return
    }
    let output = SmartTextOutput(permissionsManager: permissions, appSettings: settings)
    let result = output.output(text: text)
    if let error = result.error {
      let remedy = DeliverySettingsRemedy.forOutput(
        error: error,
        warning: nil,
        focusMovedToOtherApplication: false,
        configuration: DeliverySettingsRemedy.Configuration(settings: settings)
      )
      main.offerDeliveryRemedy(remedy)
      hud.finishFailure(
        headline: MainManager.deliveryFailureHeadline(for: error),
        message: remedy.annotate(error.localizedDescription)
      )
    }
  }
}
